import Foundation

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var activeTasks: [UUID: URLSessionDownloadTask] = [:]

    private let appState: AppState
    private var cancellingIDs = Set<UUID>()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.videosaver.downloads"
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }()

    init(appState: AppState) {
        self.appState = appState
        super.init()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        _ = session
    }

    func enqueue(
        title: String,
        variant: VideoVariant,
        referer: URL?,
        cookieHeader: String? = nil
    ) {
        let record = DownloadRecord(
            title: title,
            quality: variant.quality,
            format: variant.format,
            sourceURL: variant.url,
            refererURL: referer,
            cookieHeader: cookieHeader
        )

        appState.addDownload(record)
        start(record)
    }

    func retry(_ record: DownloadRecord) {
        guard record.status == .failed || record.status == .cancelled else {
            return
        }

        var updated = record
        updated.status = .queued
        updated.progress = 0
        updated.errorMessage = nil
        updated.fileURL = nil

        appState.updateDownload(updated)
        start(updated)
    }

    func cancel(_ record: DownloadRecord) {
        cancellingIDs.insert(record.id)

        if let task = activeTasks[record.id] {
            // URLSession cancellation is asynchronous. Do not remove the task
            // from the manager before the session has observed the cancellation.
            task.cancel()
        }

        var updated = record
        updated.status = .cancelled
        updated.errorMessage = nil
        appState.updateDownload(updated)
    }

    func shareableFileURL(for record: DownloadRecord) -> URL? {
        guard let url = record.fileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func deleteFile(for record: DownloadRecord) {
        if let fileURL = record.fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }

        appState.removeDownload(record)
    }

    private func start(_ record: DownloadRecord) {
        var request = URLRequest(url: record.sourceURL)
        request.httpMethod = "GET"
        request.setValue(
            "video/*,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )

        if let refererURL = record.refererURL {
            request.setValue(
                refererURL.absoluteString,
                forHTTPHeaderField: "Referer"
            )
        }

        if let cookieHeader = record.cookieHeader,
           !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let task = session.downloadTask(with: request)
        task.taskDescription = record.id.uuidString
        cancellingIDs.remove(record.id)
        activeTasks[record.id] = task

        var updated = record
        updated.status = .downloading
        appState.updateDownload(updated)

        task.resume()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard
            let idString = downloadTask.taskDescription,
            let id = UUID(uuidString: idString)
        else {
            return
        }

        // URLSession's temporary URL must be consumed during this callback.
        let stagingDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("DownloadStaging", isDirectory: true)

        let stagingURL = stagingDirectory
            .appendingPathComponent(id.uuidString + ".tmp")

        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )

            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.copyItem(
                at: location,
                to: stagingURL
            )
        } catch {
            Task { @MainActor in
                self.fail(id: id, message: error.localizedDescription)
            }
            return
        }

        Task { @MainActor in
            self.finishDownload(id: id, stagedURL: stagingURL)
        }
    }

    private func finishDownload(id: UUID, stagedURL: URL) {
        if cancellingIDs.remove(id) != nil {
            activeTasks.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }

        guard var record = appState.downloads.first(where: { $0.id == id }),
              record.status != .cancelled else {
            try? FileManager.default.removeItem(at: stagedURL)
            activeTasks.removeValue(forKey: id)
            return
        }

        let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        do {
            try FileManager.default.createDirectory(
                at: documentsDirectory,
                withIntermediateDirectories: true
            )

            let ext = record.format.isEmpty
                ? "mp4"
                : record.format.lowercased()

            let filename = Self.safeFilename(
                "\(record.title)-\(record.quality).\(ext)"
            )

            let destination = documentsDirectory
                .appendingPathComponent(filename)

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(
                at: stagedURL,
                to: destination
            )

            try? FileManager.default.removeItem(at: stagedURL)

            record.fileURL = destination
            record.status = .finished
            record.progress = 1
            record.errorMessage = nil
        } catch {
            record.status = .failed
            record.errorMessage = "保存文件失败：\(error.localizedDescription)"
        }

        activeTasks.removeValue(forKey: id)
        appState.updateDownload(record)
    }

    private func fail(id: UUID, message: String) {
        guard var record = appState.downloads.first(where: { $0.id == id }) else {
            return
        }

        record.status = .failed
        record.errorMessage = "下载失败：\(message)"

        activeTasks.removeValue(forKey: id)
        appState.updateDownload(record)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard
            let idString = downloadTask.taskDescription,
            let id = UUID(uuidString: idString),
            totalBytesExpectedToWrite > 0
        else {
            return
        }

        let progress =
            Double(totalBytesWritten) /
            Double(totalBytesExpectedToWrite)

        Task { @MainActor in
            guard !self.cancellingIDs.contains(id),
                  var record = self.appState.downloads.first(where: { $0.id == id }),
                  record.status != .cancelled else {
                return
            }

            record.progress = progress
            self.appState.updateDownload(record)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard
            let downloadTask = task as? URLSessionDownloadTask,
            let idString = downloadTask.taskDescription,
            let id = UUID(uuidString: idString),
            let error
        else {
            return
        }

        Task { @MainActor in
            if self.cancellingIDs.remove(id) != nil {
                self.activeTasks.removeValue(forKey: id)

                if var record = self.appState.downloads.first(where: { $0.id == id }) {
                    record.status = .cancelled
                    record.errorMessage = nil
                    self.appState.updateDownload(record)
                }
                return
            }

            guard
                let record = self.appState.downloads.first(where: { $0.id == id }),
                record.status != .finished
            else {
                self.activeTasks.removeValue(forKey: id)
                return
            }

            self.fail(
                id: id,
                message: error.localizedDescription
            )
        }
    }

    nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {}

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(
            charactersIn: "/\\:?%*|\"<>\n\r\t"
        )

        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "_")

        let value = String(cleaned.prefix(180))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return value.isEmpty ? "video.mp4" : value
    }
}
