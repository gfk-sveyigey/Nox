import Foundation

/// 一个分片在远端文件中的位置。分片边界是 (总大小, 分片数) 的纯函数结果，
/// 因此只要这两个值不变，重启后算出的边界必然一致，可以安全续传。
struct DownloadSegment: Codable, Equatable {
    var index: Int
    var start: Int64
    var length: Int64
}

/// 下载相关的文件落盘位置。刻意做成非 actor 隔离的枚举，
/// 这样 URLSession 的 nonisolated 回调里也能安全访问。
enum DownloadStorage {
    /// 分片、暂存等中间数据放 Application Support（用户不可见，也不会被系统当缓存清理）
    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoSaver", isDirectory: true)
    }

    static var partsRoot: URL {
        rootDirectory.appendingPathComponent("Parts", isDirectory: true)
    }

    static var stagingRoot: URL {
        rootDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func partsDirectory(for id: UUID) -> URL {
        partsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func stagingDirectory(for id: UUID) -> URL {
        stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func partName(_ index: Int) -> String {
        "segment-\(index).part"
    }

    static func partURL(in directory: URL, index: Int) -> URL {
        directory.appendingPathComponent(partName(index))
    }

    static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 已落盘的分片字节数（按分片长度封顶，避免多余字节被计入进度）
    static func totalPartSize(segments: [DownloadSegment], in directory: URL) -> Int64 {
        segments.reduce(into: Int64(0)) { result, segment in
            let size = fileSize(at: partURL(in: directory, index: segment.index))
            result += segment.length > 0 ? min(size, segment.length) : size
        }
    }

    /// 把 URLSession 产出的临时文件追加到分片文件末尾（续传时是关键：不能覆盖）
    static func append(_ source: URL, to destination: URL) -> Bool {
        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
            }

            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }

            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }

            _ = try output.seekToEnd()

            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }

            return true
        } catch {
            return false
        }
    }

    /// 按顺序合并分片为最终文件
    static func concatenate(_ parts: [URL], into destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)

        if parts.count == 1, let only = parts.first {
            // 单片时直接移动，省掉一次完整拷贝
            try FileManager.default.moveItem(at: only, to: destination)
            return
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        for part in parts {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }

            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        }
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    /// 下载中的实时统计（已下载 / 总大小 / 速度），仅内存。
    @Published private(set) var transfers: [UUID: TransferStats] = [:]

    /// 多线程下载的分片数
    static let multiThreadSegmentCount = 4
    /// 小于该体积不分片，避免为小文件发起多次请求
    private static let minimumSegmentLength: Int64 = 2 * 1024 * 1024

    private let appState: AppState
    private var cancellingIDs = Set<UUID>()
    private var speedSamples: [UUID: (bytes: Int64, date: Date, speed: Double)] = [:]
    private var progressTimer: Timer?

    /// key = task.taskIdentifier
    private var contexts: [Int: SegmentContext] = [:]
    /// 每个任务当前规划的分片
    private var plannedSegments: [UUID: [DownloadSegment]] = [:]
    /// 本次会话内确认完成的分片下标
    private var completedSegments: [UUID: Set<Int>] = [:]

    private struct SegmentContext {
        let recordID: UUID
        let segmentIndex: Int
        let partURL: URL
        let alreadyWritten: Int64
        let task: URLSessionDownloadTask
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.videosaver.downloads"
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 8
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
            at: DownloadStorage.documentsDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: DownloadStorage.partsRoot,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: DownloadStorage.stagingRoot,
            withIntermediateDirectories: true
        )
        _ = session
    }

    // MARK: - 对外接口

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

    /// 重试即「继续」：已下载的分片会保留，从断点开始。
    func retry(_ record: DownloadRecord) {
        guard record.status == .failed || record.status == .cancelled else {
            return
        }

        var updated = record
        updated.status = .queued
        updated.errorMessage = nil
        updated.fileName = nil
        updated.fileURL = nil
        // 保留 totalBytes / segmentCount / receivedBytes / progress，start 时会用磁盘上的分片重新校准

        appState.updateDownload(updated)
        start(updated)
    }

    func cancel(_ record: DownloadRecord) {
        cancellingIDs.insert(record.id)

        let identifiers = contexts
            .filter { $0.value.recordID == record.id }
            .map(\.key)

        for identifier in identifiers {
            contexts[identifier]?.task.cancel()
            contexts.removeValue(forKey: identifier)
        }

        let stats = transfers[record.id]

        var updated = record
        updated.status = .cancelled
        updated.errorMessage = nil

        if let stats, stats.bytesReceived > 0 {
            updated.receivedBytes = stats.bytesReceived
            if stats.totalBytes > 0 {
                updated.progress = min(Double(stats.bytesReceived) / Double(stats.totalBytes), 1)
            }
        }

        clearTransferStats(for: record.id)
        appState.updateDownload(updated)
    }

    /// 清空：删除记录 + 本地文件 + 未完成的分片。
    func clearFinished() {
        let removable = appState.downloads.filter {
            $0.status == .finished ||
            $0.status == .failed ||
            $0.status == .cancelled
        }

        for record in removable {
            deleteLocalArtifacts(for: record)
        }

        appState.clearFinishedDownloads()
    }

    func shareableFileURL(for record: DownloadRecord) -> URL? {
        let directory = DownloadStorage.documentsDirectory

        let candidates: [URL] = [
            record.fileName.map { directory.appendingPathComponent($0) },
            record.fileURL.map { directory.appendingPathComponent($0.lastPathComponent) }
        ].compactMap { $0 }

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func deleteFile(for record: DownloadRecord) {
        deleteLocalArtifacts(for: record)
        appState.removeDownload(record)
    }

    private func deleteLocalArtifacts(for record: DownloadRecord) {
        if let url = shareableFileURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        } else if let url = record.fileURL, url.isFileURL {
            try? FileManager.default.removeItem(at: url)
        }

        try? FileManager.default.removeItem(at: DownloadStorage.partsDirectory(for: record.id))
        try? FileManager.default.removeItem(at: DownloadStorage.stagingDirectory(for: record.id))

        plannedSegments.removeValue(forKey: record.id)
        completedSegments.removeValue(forKey: record.id)
        clearTransferStats(for: record.id)
    }

    // MARK: - 启动流程

    private func start(_ record: DownloadRecord) {
        Task { await begin(record) }
    }

    private func begin(_ record: DownloadRecord) async {
        let id = record.id
        cancellingIDs.remove(id)

        var updated = record
        updated.status = .downloading
        updated.errorMessage = nil
        appState.updateDownload(updated)

        startProgressTimerIfNeeded()

        let probe = await Self.probe(
            url: record.sourceURL,
            referer: record.refererURL,
            cookieHeader: record.cookieHeader
        )

        guard !cancellingIDs.contains(id) else { return }

        let partsDirectory = DownloadStorage.partsDirectory(for: id)

        // 服务器不支持 Range（返回 200）→ 只能单流重下，无法续传
        guard probe.supportsRanges, let totalBytes = probe.totalBytes, totalBytes > 0 else {
            try? FileManager.default.removeItem(at: partsDirectory)
            try? FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)

            let single = DownloadSegment(index: 0, start: 0, length: 0)
            plannedSegments[id] = [single]
            completedSegments[id] = []

            enqueue(
                record: updated,
                segments: [single],
                partsDirectory: partsDirectory,
                totalBytes: 0,
                useRangeHeader: false
            )
            return
        }

        // 续传的关键：沿用上次的分片数量，保证边界与磁盘上的分片一一对应
        let desiredCount = appState.experimentalMultiThreadDownload
            ? Self.multiThreadSegmentCount
            : 1

        let count: Int
        if record.totalBytes == totalBytes, let previous = record.segmentCount, previous > 0 {
            count = previous
        } else {
            count = desiredCount
        }

        let segments = Self.makeSegments(totalBytes: totalBytes, count: count)

        let resumable = record.totalBytes == totalBytes
            && record.segmentCount == segments.count
            && FileManager.default.fileExists(atPath: partsDirectory.path)

        if !resumable {
            // 远端文件变了或沿用不了旧分片 → 清空重来，避免拼出损坏文件
            try? FileManager.default.removeItem(at: partsDirectory)
        }

        try? FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)

        plannedSegments[id] = segments
        completedSegments[id] = []

        enqueue(
            record: updated,
            segments: segments,
            partsDirectory: partsDirectory,
            totalBytes: totalBytes,
            useRangeHeader: true
        )
    }

    /// 按字节范围均分。分片数会被总大小限制，避免小文件被切成一堆极短请求。
    private static func makeSegments(totalBytes: Int64, count: Int) -> [DownloadSegment] {
        let maximumCount = Int(max(1, totalBytes / minimumSegmentLength))
        let safeCount = max(1, min(count, maximumCount))

        let base = totalBytes / Int64(safeCount)

        var segments: [DownloadSegment] = []
        var start: Int64 = 0

        for index in 0..<safeCount {
            let length = index == safeCount - 1 ? totalBytes - start : base
            segments.append(DownloadSegment(index: index, start: start, length: length))
            start += length
        }

        return segments
    }

    private func enqueue(
        record: DownloadRecord,
        segments: [DownloadSegment],
        partsDirectory: URL,
        totalBytes: Int64,
        useRangeHeader: Bool
    ) {
        var onDisk: Int64 = 0
        var startedCount = 0

        for segment in segments {
            let partURL = DownloadStorage.partURL(in: partsDirectory, index: segment.index)
            let existing = segment.length > 0
                ? min(DownloadStorage.fileSize(at: partURL), segment.length)
                : 0

            onDisk += existing

            // 该分片已完整
            if segment.length > 0, existing >= segment.length {
                completedSegments[record.id, default: []].insert(segment.index)
                continue
            }

            var request = URLRequest(url: record.sourceURL)
            request.httpMethod = "GET"
            request.setValue("video/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

            if let referer = record.refererURL {
                request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            }

            if let cookie = record.cookieHeader, !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }

            if useRangeHeader, segment.length > 0 {
                let end = segment.start + segment.length - 1
                request.setValue("bytes=\(segment.start + existing)-\(end)", forHTTPHeaderField: "Range")
            }

            let task = session.downloadTask(with: request)
            task.taskDescription = record.id.uuidString

            contexts[task.taskIdentifier] = SegmentContext(
                recordID: record.id,
                segmentIndex: segment.index,
                partURL: partURL,
                alreadyWritten: existing,
                task: task
            )

            startedCount += 1
            task.resume()
        }

        var updated = record
        updated.totalBytes = totalBytes > 0 ? totalBytes : nil
        updated.segmentCount = segments.count
        updated.receivedBytes = onDisk
        if totalBytes > 0 {
            updated.progress = min(Double(onDisk) / Double(totalBytes), 1)
        }
        updated.status = .downloading
        appState.updateDownload(updated)

        transfers[record.id] = TransferStats(
            bytesReceived: onDisk,
            totalBytes: max(totalBytes, 0)
        )
        speedSamples[record.id] = (onDisk, Date(), 0)

        // 所有分片在磁盘上已齐（例如上次刚好下完就被杀）→ 直接合成
        if startedCount == 0 {
            Task { await finishIfComplete(recordID: record.id) }
        }
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
        guard !contexts.isEmpty else {
            stopProgressTimer()
            return
        }

        let now = Date()

        // 本次运行中、尚未追加到分片文件的字节数
        var inFlightBytes: [UUID: Int64] = [:]
        for context in contexts.values {
            inFlightBytes[context.recordID, default: 0] += max(context.task.countOfBytesReceived, 0)
        }

        for (id, inFlight) in inFlightBytes {
            guard !cancellingIDs.contains(id),
                  var record = appState.downloads.first(where: { $0.id == id }),
                  record.status == .downloading else {
                continue
            }

            let segments = plannedSegments[id] ?? []
            let onDisk = DownloadStorage.totalPartSize(
                segments: segments,
                in: DownloadStorage.partsDirectory(for: id)
            )

            let total = record.totalBytes ?? 0
            let received = onDisk + inFlight

            var speed: Double = 0
            if let previous = speedSamples[id] {
                let interval = now.timeIntervalSince(previous.date)

                if interval > 0 {
                    let delta = received - previous.bytes

                    if delta >= 0 {
                        let instantaneous = Double(delta) / interval
                        speed = previous.speed > 0
                            ? previous.speed * 0.6 + instantaneous * 0.4
                            : instantaneous
                    }
                }
            }

            speedSamples[id] = (received, now, speed)

            transfers[id] = TransferStats(
                bytesReceived: received,
                totalBytes: total,
                bytesPerSecond: speed
            )

            record.receivedBytes = received
            if total > 0 {
                record.progress = min(Double(received) / Double(total), 1)
            }

            // 高频刷新只改内存，不写 UserDefaults
            appState.updateDownload(record, persist: false)
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
            let recordID = UUID(uuidString: idString)
        else {
            return
        }

        // URLSession 的临时文件必须在本回调内消费掉，
        // 所以这里同步搬到 Staging，再回主线程追加到分片文件。
        let stagingDirectory = DownloadStorage.stagingDirectory(for: recordID)
        let stagingURL = stagingDirectory
            .appendingPathComponent("staging-\(downloadTask.taskIdentifier).part")

        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )

            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.copyItem(at: location, to: stagingURL)
        } catch {
            Task { @MainActor in
                self.abort(id: recordID, message: error.localizedDescription)
            }
            return
        }

        let identifier = downloadTask.taskIdentifier

        Task { @MainActor in
            await self.completeSegment(
                taskIdentifier: identifier,
                stagingURL: stagingURL,
                recordID: recordID
            )
        }
    }

    private func completeSegment(
        taskIdentifier: Int,
        stagingURL: URL,
        recordID: UUID
    ) async {
        guard let context = contexts.removeValue(forKey: taskIdentifier) else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }

        let partURL = context.partURL
        let segmentIndex = context.segmentIndex

        // 大文件追加放到后台线程，避免阻塞主线程
        let appended = await Task.detached(priority: .utility) {
            DownloadStorage.append(stagingURL, to: partURL)
        }.value

        try? FileManager.default.removeItem(at: stagingURL)

        guard appended else {
            abort(id: recordID, message: "写入分片文件失败")
            return
        }

        completedSegments[recordID, default: []].insert(segmentIndex)

        guard !cancellingIDs.contains(recordID) else { return }

        await finishIfComplete(recordID: recordID)
    }

    private func finishIfComplete(recordID: UUID) async {
        guard !cancellingIDs.contains(recordID) else { return }
        guard let segments = plannedSegments[recordID], !segments.isEmpty else { return }

        let partsDirectory = DownloadStorage.partsDirectory(for: recordID)
        let completed = completedSegments[recordID] ?? []

        let allDone = segments.allSatisfy { segment in
            if completed.contains(segment.index) { return true }
            guard segment.length > 0 else { return false }
            return DownloadStorage.fileSize(
                at: DownloadStorage.partURL(in: partsDirectory, index: segment.index)
            ) >= segment.length
        }

        guard allDone else { return }

        await assemble(recordID: recordID, segments: segments, partsDirectory: partsDirectory)
    }

    private func assemble(
        recordID: UUID,
        segments: [DownloadSegment],
        partsDirectory: URL
    ) async {
        guard var record = appState.downloads.first(where: { $0.id == recordID }) else { return }
        guard record.status != .cancelled else { return }

        let documentsDirectory = DownloadStorage.documentsDirectory

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

            let parts = segments
                .sorted { $0.index < $1.index }
                .map { DownloadStorage.partURL(in: partsDirectory, index: $0.index) }

            try await Task.detached(priority: .utility) {
                try DownloadStorage.concatenate(parts, into: destination)
            }.value

            record.fileName = filename
            record.fileURL = destination
            record.status = .finished
            record.progress = 1
            record.errorMessage = nil
            if let total = record.totalBytes {
                record.receivedBytes = total
            }
        } catch {
            record.status = .failed
            record.errorMessage = "保存文件失败：\(error.localizedDescription)"
        }

        try? FileManager.default.removeItem(at: partsDirectory)
        try? FileManager.default.removeItem(at: DownloadStorage.stagingDirectory(for: recordID))

        plannedSegments.removeValue(forKey: recordID)
        completedSegments.removeValue(forKey: recordID)
        clearTransferStats(for: recordID)

        appState.updateDownload(record)
    }

    // MARK: - 探测（Range 支持 / 总大小）

    private struct ProbeResult {
        var supportsRanges: Bool
        var totalBytes: Int64?
    }

    /// 用 `Range: bytes=0-0` 探一次：拿到 206 + Content-Range 就说明支持续传，
    /// 顺便取得文件总大小；返回 200 说明服务器忽略了 Range，只能整文件重下。
    private static func probe(
        url: URL,
        referer: URL?,
        cookieHeader: String?
    ) async -> ProbeResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("video/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                return ProbeResult(supportsRanges: false, totalBytes: nil)
            }

            if http.statusCode == 206,
               let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let total = totalBytes(fromContentRange: contentRange) {
                return ProbeResult(supportsRanges: true, totalBytes: total)
            }

            let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
            return ProbeResult(supportsRanges: false, totalBytes: length)
        } catch {
            return ProbeResult(supportsRanges: false, totalBytes: nil)
        }
    }

    /// 解析 `Content-Range: bytes 0-0/123456`
    private static func totalBytes(fromContentRange value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard total != "*" else { return nil }
        return Int64(total)
    }

    // MARK: - 文件名

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")

        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "_")

        let value = String(cleaned.prefix(180))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return value.isEmpty ? "video.mp4" : value
    }

    private func abort(id: UUID, message: String) {
        // 一个分片失败即整体失败；其余分片取消，但分片文件保留，方便重试续传
        let identifiers = contexts
            .filter { $0.value.recordID == id }
            .map(\.key)

        for identifier in identifiers {
            contexts[identifier]?.task.cancel()
            contexts.removeValue(forKey: identifier)
        }

        guard var record = appState.downloads.first(where: { $0.id == id }) else { return }
        guard record.status == .downloading else { return }

        record.status = .failed
        record.errorMessage = "下载失败：\(message)"

        if let stats = transfers[id], stats.bytesReceived > 0 {
            record.receivedBytes = stats.bytesReceived
        }

        clearTransferStats(for: id)
        appState.updateDownload(record)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // 成功完成由 didFinishDownloadingTo 处理，这里只处理错误
        guard let error else { return }

        let identifier = task.taskIdentifier

        Task { @MainActor in
            guard let context = self.contexts.removeValue(forKey: identifier) else { return }

            let id = context.recordID

            if self.cancellingIDs.remove(id) != nil {
                // 用户在 cancel() 里已经改过状态，这里只做兜底
                if var record = self.appState.downloads.first(where: { $0.id == id }),
                   record.status != .cancelled {
                    record.status = .cancelled
                    record.errorMessage = nil
                    self.appState.updateDownload(record)
                }
                return
            }

            self.abort(
                id: id,
                message: error.localizedDescription
            )
        }
    }

    nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {}
}