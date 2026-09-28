import Foundation

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var activeTasks: [UUID: URLSessionDownloadTask] = [:]

    private let appState: AppState
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.videosaver.downloads")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(appState: AppState) {
        self.appState = appState
        super.init()
        _ = session
    }

    func enqueue(title: String, variant: VideoVariant, referer: URL?, cookieHeader: String? = nil) {
        let record = DownloadRecord(title: title, quality: variant.quality, format: variant.format, sourceURL: variant.url)
        appState.addDownload(record)
        var request = URLRequest(url: variant.url)
        request.httpMethod = "GET"
        request.setValue("video/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        if let cookieHeader, !cookieHeader.isEmpty { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        let task = session.downloadTask(with: request)
        task.taskDescription = record.id.uuidString
        activeTasks[record.id] = task
        var updated = record
        updated.status = .downloading
        appState.updateDownload(updated)
        task.resume()
    }

    func cancel(_ record: DownloadRecord) {
        activeTasks[record.id]?.cancel()
        activeTasks.removeValue(forKey: record.id)
        var updated = record
        updated.status = .cancelled
        appState.updateDownload(updated)
    }

    func deleteFile(for record: DownloadRecord) {
        if let fileURL = record.fileURL { try? FileManager.default.removeItem(at: fileURL) }
        appState.removeDownload(record)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let idString = downloadTask.taskDescription,
              let id = UUID(uuidString: idString) else { return }
        Task { @MainActor in
            self.finishDownload(id: id, temporaryURL: location)
        }
    }

    private func finishDownload(id: UUID, temporaryURL location: URL) {
        guard var record = appState.downloads.first(where: { $0.id == id }) else { return }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ext = record.format.isEmpty ? "mp4" : record.format.lowercased()
        let filename = Self.safeFilename("\(record.title)-\(record.quality).\(ext)")
        let destination = folder.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            record.fileURL = destination
            record.status = .finished
            record.progress = 1
            record.errorMessage = nil
        } catch {
            record.status = .failed
            record.errorMessage = error.localizedDescription
        }
        activeTasks.removeValue(forKey: id)
        appState.updateDownload(record)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let idString = downloadTask.taskDescription, let id = UUID(uuidString: idString), totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            guard var record = self.appState.downloads.first(where: { $0.id == id }) else { return }
            record.progress = progress
            self.appState.updateDownload(record)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask, let idString = downloadTask.taskDescription, let id = UUID(uuidString: idString), let error else { return }
        Task { @MainActor in
            guard var record = self.appState.downloads.first(where: { $0.id == id }) else { return }
            if record.status != .finished {
                record.status = .failed
                record.errorMessage = error.localizedDescription
                self.activeTasks.removeValue(forKey: id)
                self.appState.updateDownload(record)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // The app can reconnect to the background session after relaunch.
    }

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        return String(cleaned.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "video.mp4" : String(cleaned.prefix(180))
    }
}
