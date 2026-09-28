import Foundation

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var activeTasks: [UUID: URLSessionDownloadTask] = [:]
    /// 下载中的实时统计（已下载 / 总大小 / 速度），仅内存。
    @Published private(set) var transfers: [UUID: TransferStats] = [:]

    private let appState: AppState
    private var cancellingIDs = Set<UUID>()
    private var speedSamples: [UUID: (bytes: Int64, date: Date, speed: Double)] = [:]
    private var progressTimer: Timer?

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
        try? FileManager.default.createDirectory(
            at: Self.documentsDirectory,
            withIntermediateDirectories: true
        )
        _ = session
    }

    /// 每次都实时解析，避免持久化绝对路径。
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
        updated.fileName = nil
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

        clearTransferStats(for: record.id)

        var updated = record
        updated.status = .cancelled
        updated.errorMessage = nil
        appState.updateDownload(updated)
    }

    /// 解析出真实存在的本地文件地址：
    /// 1) 优先用记录里的文件名拼当前的 Documents 路径；
    /// 2) 旧记录只有绝对路径时，取最后一段文件名重新拼（容器 UUID 变了也能命中）。
    func shareableFileURL(for record: DownloadRecord) -> URL? {
        let directory = Self.documentsDirectory

        let candidates: [URL] = [
            record.fileName.map { directory.appendingPathComponent($0) },
            record.fileURL.map { directory.appendingPathComponent($0.lastPathComponent) }
        ].compactMap { $0 }

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func deleteFile(for record: DownloadRecord) {
        if let fileURL = shareableFileURL(for: record) {
            try? FileManager.default.removeItem(at: fileURL)
        } else if let fileURL = record.fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }

        clearTransferStats(for: record.id)
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

        // 初始化统计采样，第一秒即可算出速度
        speedSamples[record.id] = (0, Date(), 0)
        transfers[record.id] = TransferStats()

        var updated = record
        updated.status = .downloading
        appState.updateDownload(updated)

        startProgressTimerIfNeeded()
        task.resume()
    }

    // MARK: - 进度 / 速度

    private func startProgressTimerIfNeeded() {
        guard progressTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickProgress()
            }
        }

        // 必须加到 .common，否则滚动列表时计时器暂停、进度会卡住
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tickProgress() {
        guard !activeTasks.isEmpty else {
            stopProgressTimer()
            return
        }

        let now = Date()

        for (id, task) in activeTasks {
            guard !cancellingIDs.contains(id),
                  var record = appState.downloads.first(where: { $0.id == id }),
                  record.status == .downloading else {
                continue
            }

            let received = max(task.countOfBytesReceived, 0)
            let expected = task.countOfBytesExpectedToReceive

            var speed: Double = 0

            if let previous = speedSamples[id] {
                let interval = now.timeIntervalSince(previous.date)

                if interval > 0 {
                    let delta = received - previous.bytes

                    if delta >= 0 {
                        let instantaneous = Double(delta) / interval
                        // 指数平滑，避免速度数字跳动
                        speed = previous.speed > 0
                            ? previous.speed * 0.6 + instantaneous * 0.4
                            : instantaneous
                    }
                }
            }

            speedSamples[id] = (received, now, speed)

            transfers[id] = TransferStats(
                bytesReceived: received,
                totalBytes: max(expected, 0),
                bytesPerSecond: speed
            )

            if expected > 0 {
                record.progress = min(Double(received) / Double(expected), 1)
                appState.updateDownload(record)
            }
        }
    }

    private func clearTransferStats(for id: UUID) {
        transfers.removeValue(forKey: id)
        speedSamples.removeValue(forKey: id)
    }

    // MARK: - URLSessionDownloadDelegate

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
        clearTransferStats(for: id)

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

        let documentsDirectory = Self.documentsDirectory

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

            // 复制失败必须抛错，否则会出现「已完成但没有文件」的记录。
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(
                at: stagedURL,
                to: destination
            )

            try? FileManager.default.removeItem(at: stagedURL)

            record.fileName = filename
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
        clearTransferStats(for: id)

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
                  record.status == .downloading else {
                return
            }

            record.progress = progress
            // 高频进度只改内存，不写 UserDefaults
            self.appState.updateDownload(record, persist: false)
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
                self.clearTransferStats(for: id)

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
                self.clearTransferStats(for: id)
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