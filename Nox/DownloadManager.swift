import Foundation
import WebKit

/// 一个分片在远端文件中的位置。分片边界是 (总大小, 固定分片长度) 的纯函数结果，
/// 与线程数无关，因此改动线程数不会让已下载的分片作废，可以安全续传。
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
        return base.appendingPathComponent("Nox", isDirectory: true)
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

    /// WebKit 的数据目录（网站数据、网页缓存落在这里）。
    ///
    /// 没有公开 API 能取到 `WKWebsiteDataStore` 的占用，只能按目录估算；
    /// 目录不存在时返回 0。
    static var webKitDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKit", isDirectory: true)
    }

    static func partsDirectory(for id: UUID) -> URL {
        partsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func stagingDirectory(for id: UUID) -> URL {
        stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func partName(_ index: Int) -> String {
        String(format: "segment-%06d.part", index)
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

    /// 状态是「已完成」但本地文件已经不在了的记录（启动时扫描发现）。
    /// 列表据此提示「文件缺失」，并隐藏分享入口。
    @Published private(set) var missingFileIDs: Set<UUID> = []

    /// 每个分片的目标大小。
    ///
    /// 必须是**固定值**：分片边界只由 (总大小, 本值) 决定，与线程数无关。
    /// 之前按「线程数」切分，导致关闭多线程时整个文件只有 1 个分片 ——
    /// 分片未下完前不会落盘，于是取消/失败等于进度全丢。
    private static let segmentLength: Int64 = 4 * 1024 * 1024

    private let appState: AppState
    private var cancellingIDs = Set<UUID>()
    private var speedSamples: [UUID: (bytes: Int64, date: Date, speed: Double)] = [:]
    private var progressTimer: Timer?

    // MARK: - 全局并发调度

    /// 同时进行的**任务**数上限。
    ///
    /// 这是任务数而不是连接数：每个任务内部还会开若干分片连接，
    /// 实际连接总数 ≈ 本值 × 单任务并发。
    private var maxConcurrentTasks: Int {
        let configured = appState.maxConcurrentDownloads

        // 「无限制」用 0 表示：上限取 Int.max，队列有多少就跑多少。
        guard configured != AppState.unlimitedConcurrentDownloads else { return .max }

        return max(1, configured)
    }

    /// 已占用槽位的任务（探测中 / 下载中 / HLS 合并中）
    private var activeIDs = Set<UUID>()
    /// 排队等待槽位的任务，先进先出
    private var pendingQueue: [UUID] = []
    /// 每个任务的调度句柄；取消它会一路中止其内部的 async 工作
    private var slotTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - 单任务内的分片调度

    /// 待下载的分片下标（FIFO）。用显式队列而不是一次性起全部 task，
    /// 才能让「并发数」真正生效。
    private var pendingSegments: [UUID: [Int]] = [:]
    /// 当前在飞的分片数
    private var inFlightSegments: [UUID: Int] = [:]
    /// 该任务启动时快照下来的并发上限
    private var recordConcurrency: [UUID: Int] = [:]
    /// HLS 最近一次上报的进度；速度统一由 1 秒定时器计算，避免分片成批完成时抖动
    private var hlsProgress: [UUID: HLSDownloader.Progress] = [:]

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
            withIdentifier: "com.aholic.nox.downloads"
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        // 允许多线程设置最大到 32 条并发连接
        configuration.httpMaximumConnectionsPerHost = AppState.segmentCountRange.upperBound
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

        // 启动时扫一遍：上次运行留下的「已完成」记录，文件可能已被系统清理或用户删除。
        refreshMissingFiles()
    }

    /// 重新扫描「已完成但文件缺失」的记录。
    func refreshMissingFiles() {
        var missing = Set<UUID>()

        for record in appState.downloads where record.status == .finished {
            if shareableFileURL(for: record) == nil {
                missing.insert(record.id)
            }
        }

        missingFileIDs = missing

        if !missing.isEmpty {
            LogStore.shared.warning("missing files: \(missing.count)")
        }
    }

    // MARK: - 对外接口

    func enqueue(
        title: String,
        variant: VideoVariant,
        referer: URL?,
        cookieHeader: String? = nil,
        filename: String? = nil
    ) {
        let record = DownloadRecord(
            title: title,
            quality: variant.quality,
            format: variant.format,
            sourceURL: variant.url,
            refererURL: referer,
            cookieHeader: cookieHeader,
            desiredFilename: filename
        )

        appState.addDownload(record)

        // 历史在这里（真正入队下载时）记录，而不是解析时：
        // 解析了但没下载、或下载被取消，都不该在历史里留下痕迹。
        // 历史标题用文件名（去扩展名），而不是页面标题。
        appState.addHistory(title: record.displayTitle, url: referer ?? record.sourceURL)

        LogStore.shared.info("enqueue \(record.displayFilename) [\(record.quality)/\(record.format)] <- \(referer?.absoluteString ?? record.sourceURL.absoluteString)")

        start(record)
    }

    /// 供「选择文件名」弹窗预填：按 `title-quality.ext` 生成，并避开 Documents 里的同名文件。
    func suggestedFilename(title: String, quality: String, format: String) -> String {
        let ext = Self.fileExtension(for: format)
        return Self.uniqueFilename("\(title)-\(quality).\(ext)")
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

        // 取消时历史已被清掉，重试相当于重新入队，补回一条。
        appState.addHistory(title: updated.displayTitle, url: updated.refererURL ?? updated.sourceURL)
        LogStore.shared.info("retry \(updated.displayFilename)")

        start(updated)
    }

    /// 批量重试（多选时用）
    func retryAll(ids: Set<UUID>) {
        for record in appState.downloads where ids.contains(record.id) {
            retry(record)
        }
    }

    func cancel(_ record: DownloadRecord) {
        cancellingIDs.insert(record.id)

        // 还在排队就直接出队，否则槽位空出来时它会莫名其妙地开始下载
        if let index = pendingQueue.firstIndex(of: record.id) {
            pendingQueue.remove(at: index)
        }

        // 普通下载靠 contexts 里的 URLSessionDownloadTask 取消；
        // HLS 用的是 async URLSession，只能靠取消调度句柄（CancellationError 会向下传播）。
        slotTasks[record.id]?.cancel()

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

        resetScheduling(for: record.id)
        clearTransferStats(for: record.id)
        appState.updateDownload(updated)
        releaseSlot(record.id)

        LogStore.shared.info("cancel \(updated.displayFilename)")

        // 被取消的任务不该留在历史里；但同一页面若还有其它未取消的下载，则保留。
        removeHistoryIfUnused(for: updated)
    }

    /// 取消 / 删除后，若该页面已没有任何仍在队列、下载中或已完成的记录，
    /// 就把它的历史条目一并清掉。
    private func removeHistoryIfUnused(for record: DownloadRecord) {
        let pageURL = record.refererURL ?? record.sourceURL
        let identity = pageURL.pageIdentity

        let hasOther = appState.downloads.contains { other in
            other.id != record.id
                && (other.refererURL ?? other.sourceURL).pageIdentity == identity
                && other.status != .cancelled
                && other.status != .failed
        }

        guard !hasOther else { return }
        appState.removeHistory(matching: pageURL)
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
        refreshMissingFiles()
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
        refreshMissingFiles()
    }

    /// 批量删除（多选时用）。先快照再删，避免边遍历边修改 downloads。
    func deleteFiles(ids: Set<UUID>) {
        let targets = appState.downloads.filter { ids.contains($0.id) }

        for record in targets {
            deleteFile(for: record)
        }
    }

    private func deleteLocalArtifacts(for record: DownloadRecord) {
        // 先停掉可能还在跑的调度任务与网络请求，再删文件，
        // 否则删完文件后请求回调仍会往分片目录写。
        slotTasks[record.id]?.cancel()

        if let url = shareableFileURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        } else if let url = record.fileURL, url.isFileURL {
            try? FileManager.default.removeItem(at: url)
        }

        try? FileManager.default.removeItem(at: DownloadStorage.partsDirectory(for: record.id))
        try? FileManager.default.removeItem(at: DownloadStorage.stagingDirectory(for: record.id))

        resetScheduling(for: record.id)
        clearTransferStats(for: record.id)
        releaseSlot(record.id)
    }

    // MARK: - 缓存（未完成的分片与暂存文件）

    /// 缓存占用：`Parts` 与 `Staging` 两个目录的字节数。
    ///
    /// 不含 `Documents`（已下载的视频），也不含 WKWebView 的网站数据
    /// —— 后者含登录态，清掉会把用户退出登录。
    func cacheSize() -> Int64 {
        partsSize() + stagingSize()
    }

    /// 未完成下载的分片占用
    func partsSize() -> Int64 {
        Self.directorySize(DownloadStorage.partsRoot)
    }

    /// 暂存（分片合并前的落盘中转）占用
    func stagingSize() -> Int64 {
        Self.directorySize(DownloadStorage.stagingRoot)
    }

    /// HTTP 网络缓存占用（探测 / 清单请求留下的响应）
    func networkCacheSize() -> Int64 {
        let cache = URLCache.shared
        return Int64(cache.currentDiskUsage + cache.currentMemoryUsage)
    }

    /// 网站数据占用（Cookie、本地存储、网页缓存），按 WebKit 数据目录估算。
    func websiteDataSize() -> Int64 {
        Self.directorySize(DownloadStorage.webKitDirectory)
    }

    /// 已下载视频占用的空间（`Documents` 目录）。
    /// 与缓存分开统计，方便在「储存空间」里告诉用户「删掉这些能省多少」。
    func documentsSize() -> Int64 {
        Self.directorySize(DownloadStorage.documentsDirectory)
    }

    /// App 回到前台时调用：丢弃后台期间的速度采样。
    ///
    /// 后台时进度定时器不会触发，若沿用暂停前的采样点，第一帧会拿「跨越整个后台的时间差」
    /// 去算瞬时速度，得到明显偏离真实值的数字。重置后从当前字节数重新起算。
    func resetSpeedSamples() {
        let now = Date()

        for id in Array(speedSamples.keys) {
            let bytes = speedSamples[id]?.bytes ?? 0
            speedSamples[id] = (bytes, now, 0)

            if var stats = transfers[id] {
                stats.bytesPerSecond = 0
                transfers[id] = stats
            }
        }
    }

    /// 清空缓存：删除未完成下载的分片与暂存文件，以及 HTTP 网络缓存。
    ///
    /// 已完成的视频在 `Documents`，不受影响（其分片目录在完成时就已经清理）。
    func clearCache() {
        clearParts()
        clearStaging()
        clearNetworkCache()
    }

    /// 清理未完成下载的分片。
    ///
    /// 正在下载 / 排队中的任务会被跳过，否则会把它们正在写的文件删掉。
    func clearParts() {
        Self.removeSubdirectories(
            in: DownloadStorage.partsRoot,
            keeping: activeIDs.union(pendingQueue)
        )
    }

    /// 清理暂存文件（同样跳过正在下载 / 排队中的任务）
    func clearStaging() {
        Self.removeSubdirectories(
            in: DownloadStorage.stagingRoot,
            keeping: activeIDs.union(pendingQueue)
        )
    }

    /// 清理 HTTP 网络缓存
    func clearNetworkCache() {
        URLCache.shared.removeAllCachedResponses()
    }

    /// 清理网站数据（Cookie / 本地存储 / 网页缓存）。
    ///
    /// - Warning: 会一并清掉登录态，用户需要重新登录相关网站。
    func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return 0
        }

        var total: Int64 = 0

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])

            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }

        return total
    }

    /// 删除目录下的一级子目录，`keep` 中的 UUID 目录除外。
    /// 散落的非目录条目（临时文件）一并删除。
    private static func removeSubdirectories(in directory: URL, keeping keep: Set<UUID>) {
        let fileManager = FileManager.default

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            guard isDirectory, let id = UUID(uuidString: entry.lastPathComponent) else {
                try? fileManager.removeItem(at: entry)
                continue
            }

            guard !keep.contains(id) else { continue }

            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: - 任务级调度

    private func start(_ record: DownloadRecord) {
        guard !activeIDs.contains(record.id), !pendingQueue.contains(record.id) else { return }

        pendingQueue.append(record.id)
        drainQueue()
    }

    private func drainQueue() {
        while activeIDs.count < maxConcurrentTasks, !pendingQueue.isEmpty {
            let id = pendingQueue.removeFirst()

            guard let record = appState.downloads.first(where: { $0.id == id }) else { continue }

            activeIDs.insert(id)

            slotTasks[id] = Task { [weak self] in
                await self?.begin(record)

                // begin 返回 ≠ 下载结束：普通下载此时分片还在飞，
                // 要等 assemble / abort 把它推进终态才释放槽位。
                self?.releaseSlotIfSettled(id)
            }
        }
    }

    private func releaseSlotIfSettled(_ id: UUID) {
        guard let status = appState.downloads.first(where: { $0.id == id })?.status else {
            releaseSlot(id)
            return
        }

        guard status != .queued, status != .downloading else { return }
        releaseSlot(id)
    }

    /// 幂等：重复调用不会重复触发 `drainQueue`。
    private func releaseSlot(_ id: UUID) {
        guard activeIDs.remove(id) != nil else { return }

        slotTasks.removeValue(forKey: id)
        drainQueue()
    }

    // MARK: - 启动流程

    private func begin(_ record: DownloadRecord) async {
        // 排队期间被取消：调度句柄已被 cancel，直接退出。
        // 必须在清除 cancellingIDs 之前判断，否则会把这个取消标记抹掉。
        if Task.isCancelled { return }

        // m3u8 走独立管线：清单 → 分片 → AES-128 解密 → 合并。
        // 它的总大小事先未知、分片数量由清单决定，套用字节分片逻辑没有意义。
        if record.format.lowercased() == "m3u8" {
            await beginHLS(record)
            return
        }

        let id = record.id
        cancellingIDs.remove(id)

        var updated = record
        updated.status = .downloading
        updated.errorMessage = nil
        appState.updateDownload(updated)

        // 先把统计挂上，探测期间列表不会空着
        let resumeBytes = record.receivedBytes ?? 0
        transfers[id] = TransferStats(
            bytesReceived: resumeBytes,
            totalBytes: record.totalBytes ?? 0
        )
        speedSamples[id] = (resumeBytes, Date(), 0)

        startProgressTimerIfNeeded()

        let probe = await Self.probe(
            url: record.sourceURL,
            referer: record.refererURL,
            cookieHeader: record.cookieHeader
        )

        guard !cancellingIDs.contains(id) else { return }

        // 探测本身失败（网络抖动 / 超时）时**不要**动分片目录：
        // 已经下好的分片仍然是有效的，清掉就等于让用户白白重下。
        if probe.failed {
            abort(id: id, message: L("无法获取文件信息，请稍后重试。"))
            return
        }

        let partsDirectory = DownloadStorage.partsDirectory(for: id)

        // 服务器不支持 Range（返回 200）→ 只能整文件重下，无法续传
        guard probe.supportsRanges, let totalBytes = probe.totalBytes, totalBytes > 0 else {
            try? FileManager.default.removeItem(at: partsDirectory)
            try? FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)

            schedule(
                record: updated,
                segments: [DownloadSegment(index: 0, start: 0, length: 0)],
                totalBytes: 0,
                concurrency: 1
            )
            return
        }

        let segments = Self.makeSegments(totalBytes: totalBytes)

        // 续传判据：远端大小一致、分片布局一致、分片目录还在。
        // 任何一条不满足就整批作废，避免把不对齐的分片拼成损坏文件。
        let resumable = record.totalBytes == totalBytes
            && record.segmentCount == segments.count
            && FileManager.default.fileExists(atPath: partsDirectory.path)

        if !resumable {
            try? FileManager.default.removeItem(at: partsDirectory)
        }

        try? FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)

        let concurrency = appState.experimentalMultiThreadDownload
            ? max(1, min(appState.multiThreadSegmentCount, AppState.segmentCountRange.upperBound))
            : 1

        schedule(
            record: updated,
            segments: segments,
            totalBytes: totalBytes,
            concurrency: concurrency
        )
    }

    /// 按固定长度均分。数量只取决于总大小，因此线程数变化不会让旧分片失效。
    private static func makeSegments(totalBytes: Int64) -> [DownloadSegment] {
        guard totalBytes > 0 else {
            return [DownloadSegment(index: 0, start: 0, length: 0)]
        }

        let count = Int((totalBytes + segmentLength - 1) / segmentLength)

        var segments: [DownloadSegment] = []
        segments.reserveCapacity(count)

        var start: Int64 = 0

        for index in 0..<count {
            let end = min(start + segmentLength, totalBytes)
            segments.append(DownloadSegment(index: index, start: start, length: end - start))
            start = end
        }

        return segments
    }

    /// 登记分片计划并启动第一批下载。
    private func schedule(
        record: DownloadRecord,
        segments: [DownloadSegment],
        totalBytes: Int64,
        concurrency: Int
    ) {
        let id = record.id
        let partsDirectory = DownloadStorage.partsDirectory(for: id)

        var onDisk: Int64 = 0
        var pending: [Int] = []

        for segment in segments {
            let partURL = DownloadStorage.partURL(in: partsDirectory, index: segment.index)
            let existing = segment.length > 0
                ? min(DownloadStorage.fileSize(at: partURL), segment.length)
                : 0

            onDisk += existing

            if segment.length > 0, existing >= segment.length {
                completedSegments[id, default: []].insert(segment.index)
            } else {
                pending.append(segment.index)
            }
        }

        plannedSegments[id] = segments
        pendingSegments[id] = pending
        inFlightSegments[id] = 0
        recordConcurrency[id] = max(1, concurrency)

        var updated = record
        updated.totalBytes = totalBytes > 0 ? totalBytes : nil
        updated.segmentCount = segments.count
        updated.threadCount = max(1, concurrency)
        updated.receivedBytes = onDisk
        if totalBytes > 0 {
            updated.progress = min(Double(onDisk) / Double(totalBytes), 1)
        }
        updated.status = .downloading
        appState.updateDownload(updated)

        transfers[id] = TransferStats(
            bytesReceived: onDisk,
            totalBytes: max(totalBytes, 0)
        )
        speedSamples[id] = (onDisk, Date(), 0)

        pumpSegments(recordID: id)
        startProgressTimerIfNeeded()
    }

    /// 在并发上限内继续取分片开工；全部完成时收尾。
    private func pumpSegments(recordID: UUID) {
        guard !cancellingIDs.contains(recordID) else { return }
        guard let segments = plannedSegments[recordID] else { return }

        let limit = recordConcurrency[recordID] ?? 1

        while (inFlightSegments[recordID] ?? 0) < limit {
            guard var queue = pendingSegments[recordID], !queue.isEmpty else { break }

            let index = queue.removeFirst()
            pendingSegments[recordID] = queue

            guard index < segments.count else { continue }
            startSegment(recordID: recordID, segment: segments[index], index: index)
        }

        if (pendingSegments[recordID] ?? []).isEmpty, (inFlightSegments[recordID] ?? 0) == 0 {
            Task { await finishIfComplete(recordID: recordID) }
        }
    }

    private func startSegment(recordID: UUID, segment: DownloadSegment, index: Int) {
        guard let record = appState.downloads.first(where: { $0.id == recordID }) else { return }

        let partsDirectory = DownloadStorage.partsDirectory(for: recordID)
        let partURL = DownloadStorage.partURL(in: partsDirectory, index: index)
        let existing = segment.length > 0
            ? min(DownloadStorage.fileSize(at: partURL), segment.length)
            : 0

        var request = URLRequest(url: record.sourceURL)
        request.httpMethod = "GET"
        request.setValue("video/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        if let referer = record.refererURL {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        if let cookie = record.cookieHeader, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        // length == 0 表示「整文件单流」（服务器不支持 Range），此时不加 Range 头
        if segment.length > 0 {
            let end = segment.start + segment.length - 1
            request.setValue("bytes=\(segment.start + existing)-\(end)", forHTTPHeaderField: "Range")
        }

        let task = session.downloadTask(with: request)
        task.taskDescription = recordID.uuidString

        contexts[task.taskIdentifier] = SegmentContext(
            recordID: recordID,
            segmentIndex: index,
            partURL: partURL,
            alreadyWritten: existing,
            task: task
        )

        inFlightSegments[recordID, default: 0] += 1
        task.resume()
    }

    private func resetScheduling(for id: UUID) {
        pendingSegments.removeValue(forKey: id)
        inFlightSegments.removeValue(forKey: id)
        recordConcurrency.removeValue(forKey: id)
        hlsProgress.removeValue(forKey: id)
        plannedSegments.removeValue(forKey: id)
        completedSegments.removeValue(forKey: id)
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
        // 以「记录状态」而不是 contexts 判断是否还有任务。
        // begin() 里要等 probe 返回才会创建 task，若用 contexts 判断，
        // 探测超过 1 秒时第一次 tick 就会把计时器停掉，此后进度与速度再也不更新。
        let activeRecords = appState.downloads.filter { $0.status == .downloading }

        guard !activeRecords.isEmpty else {
            stopProgressTimer()
            return
        }

        let now = Date()

        // 本次运行中、尚未追加到分片文件的字节数
        var inFlightBytes: [UUID: Int64] = [:]
        for context in contexts.values {
            inFlightBytes[context.recordID, default: 0] += max(context.task.countOfBytesReceived, 0)
        }

        for record in activeRecords {
            let id = record.id

            guard !cancellingIDs.contains(id) else { continue }

            let isHLS = record.format.lowercased() == "m3u8"

            let received: Int64
            let total: Int64

            if isHLS {
                // m3u8 的字节数来自解密后的分片累计，总大小未知
                guard let snapshot = hlsProgress[id] else { continue }
                received = snapshot.bytes
                total = 0
            } else {
                let inFlight = inFlightBytes[id] ?? 0
                let segments = plannedSegments[id] ?? []
                let onDisk = DownloadStorage.totalPartSize(
                    segments: segments,
                    in: DownloadStorage.partsDirectory(for: id)
                )
                received = onDisk + inFlight
                total = record.totalBytes ?? 0
            }

            // 速度统一在 1 秒节拍上算，而不是每次分片回调都算：
            // m3u8 的分片会在同一秒内成批完成，按回调时间戳算会得到一串
            // 极短的采样区间，速度因此剧烈抖动（表现为数字乱跳、明显偏大）。
            var speed: Double = 0
            if let previous = speedSamples[id] {
                let interval = now.timeIntervalSince(previous.date)

                // 采样区间过长（App 刚从后台返回、计时器被系统暂停）时不参与计算：
                // 用旧基准点算出的「瞬时速度」会明显偏离真实值。
                if interval > 0, interval <= 5 {
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

            var updated = record
            updated.receivedBytes = received

            if isHLS {
                if let snapshot = hlsProgress[id], snapshot.total > 0 {
                    updated.progress = min(
                        Double(snapshot.completed) / Double(snapshot.total),
                        1
                    )
                }
            } else if total > 0 {
                updated.progress = min(Double(received) / Double(total), 1)
            }

            // 高频刷新只改内存，不写 UserDefaults
            appState.updateDownload(updated, persist: false)
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

        inFlightSegments[recordID] = max(0, (inFlightSegments[recordID] ?? 1) - 1)

        let partURL = context.partURL
        let segmentIndex = context.segmentIndex

        // 大文件追加放到后台线程，避免阻塞主线程
        let appended = await Task.detached(priority: .utility) {
            DownloadStorage.append(stagingURL, to: partURL)
        }.value

        try? FileManager.default.removeItem(at: stagingURL)

        guard appended else {
            abort(id: recordID, message: L("写入分片文件失败"))
            return
        }

        completedSegments[recordID, default: []].insert(segmentIndex)

        guard !cancellingIDs.contains(recordID) else { return }

        pumpSegments(recordID: recordID)
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
        defer {
            resetScheduling(for: recordID)
            releaseSlot(recordID)
        }

        guard var record = appState.downloads.first(where: { $0.id == recordID }) else { return }
        guard record.status != .cancelled else { return }

        let documentsDirectory = DownloadStorage.documentsDirectory

        do {
            try FileManager.default.createDirectory(
                at: documentsDirectory,
                withIntermediateDirectories: true
            )

            let fallback = "\(record.title)-\(record.quality).\(Self.fileExtension(for: record.format))"
            let filename = Self.uniqueFilename(record.desiredFilename ?? fallback)

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
            record.errorMessage = String(format: L("保存文件失败：%@"), error.localizedDescription)
        }

        try? FileManager.default.removeItem(at: partsDirectory)
        try? FileManager.default.removeItem(at: DownloadStorage.stagingDirectory(for: recordID))

        clearTransferStats(for: recordID)
        appState.updateDownload(record)
        logCompletion(record)
    }

    // MARK: - HLS（m3u8）

    private func beginHLS(_ record: DownloadRecord) async {
        let id = record.id
        cancellingIDs.remove(id)

        var updated = record
        updated.status = .downloading
        updated.errorMessage = nil

        // 复用「下载设置 → 多线程下载」：用户只需要理解一个并发旋钮。
        // m3u8 分片远小于字节分片（通常 2–10 秒一片、总数可达数百），
        // 所以再夹一道上限，避免打爆 CDN 触发限速或 403。
        let desired: Int

        if appState.m3u8SegmentConcurrency > 0 {
            // 显式覆盖（0 表示跟随多线程设置）
            desired = appState.m3u8SegmentConcurrency
        } else if appState.experimentalMultiThreadDownload {
            desired = appState.multiThreadSegmentCount
        } else {
            desired = AppState.defaultHLSConcurrency
        }

        let concurrency = min(max(desired, 1), AppState.maxHLSConcurrency)

        updated.threadCount = concurrency
        appState.updateDownload(updated)

        transfers[id] = TransferStats()
        speedSamples[id] = (0, Date(), 0)
        hlsProgress.removeValue(forKey: id)
        startProgressTimerIfNeeded()

        do {
            let merged = try await HLSDownloader(concurrency: concurrency).download(
                recordID: id,
                playlistURL: record.sourceURL,
                referer: record.refererURL,
                cookieHeader: record.cookieHeader,
                userAgent: nil,
                quality: appState.preferredQuality
            ) { [weak self] progress in
                // 只记录，不在回调里算速度：分片常成批完成，
                // 由 1 秒定时器统一计算，速度才稳。
                Task { @MainActor in
                    self?.hlsProgress[id] = progress
                }
            }

            guard !cancellingIDs.contains(id) else { return }

            finishHLS(recordID: id, mergedFile: merged)
        } catch is CancellationError {
            // cancel() 已经改过状态并清了统计
            return
        } catch {
            guard !cancellingIDs.contains(id) else { return }
            abort(id: id, message: error.localizedDescription)
        }
    }

    private func finishHLS(recordID: UUID, mergedFile: URL) {
        defer {
            resetScheduling(for: recordID)
            releaseSlot(recordID)
        }

        guard var record = appState.downloads.first(where: { $0.id == recordID }) else { return }
        guard record.status != .cancelled else { return }

        do {
            let directory = DownloadStorage.documentsDirectory

            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            // 合并结果统一是 MP4 容器（TS / fMP4 分片拼接后由系统播放器识别）
            let fallback = "\(record.title)-\(record.quality).mp4"
            let filename = Self.uniqueFilename(record.desiredFilename ?? fallback)
            let destination = directory.appendingPathComponent(filename)

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: mergedFile, to: destination)

            record.fileName = filename
            record.fileURL = destination
            record.status = .finished
            record.progress = 1
            record.errorMessage = nil
            record.receivedBytes = DownloadStorage.fileSize(at: destination)
        } catch {
            record.status = .failed
            record.errorMessage = String(format: L("保存文件失败：%@"), error.localizedDescription)
        }

        try? FileManager.default.removeItem(at: DownloadStorage.partsDirectory(for: recordID))
        try? FileManager.default.removeItem(at: DownloadStorage.stagingDirectory(for: recordID))

        clearTransferStats(for: recordID)
        appState.updateDownload(record)
        logCompletion(record)
    }

    // MARK: - 探测（Range 支持 / 总大小）

    private struct ProbeResult {
        var supportsRanges: Bool
        var totalBytes: Int64?
        /// 探测本身失败（网络错误 / 超时 / 非 HTTP 响应），与「服务器不支持 Range」是两回事
        var failed: Bool
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
        // URLSession.shared 带本地缓存，命中旧响应会让探测结论失真
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                return ProbeResult(supportsRanges: false, totalBytes: nil, failed: true)
            }

            if http.statusCode == 206,
               let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let total = totalBytes(fromContentRange: contentRange) {
                return ProbeResult(supportsRanges: true, totalBytes: total, failed: false)
            }

            let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
            return ProbeResult(supportsRanges: false, totalBytes: length, failed: false)
        } catch {
            return ProbeResult(supportsRanges: false, totalBytes: nil, failed: true)
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

    /// m3u8 合并后是 MP4 容器；其余按上报的格式
    private static func fileExtension(for format: String) -> String {
        let lowered = format.lowercased()
        if lowered.isEmpty || lowered == "m3u8" { return "mp4" }
        return lowered
    }

    /// 避开 Documents 里已存在的同名文件（追加 " (2)"、" (3)"…），
    /// 否则会静默覆盖用户已有的视频。
    private static func uniqueFilename(_ proposed: String) -> String {
        let directory = DownloadStorage.documentsDirectory
        let base = safeFilename(proposed)

        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(base).path
        ) else {
            return base
        }

        let url = URL(fileURLWithPath: base)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for index in 2...999 {
            let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"

            if !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(candidate).path
            ) {
                return candidate
            }
        }

        return base
    }

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
        defer {
            resetScheduling(for: id)
            releaseSlot(id)
        }

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
        record.errorMessage = String(format: L("下载失败：%@"), message)

        // 用磁盘上的分片数，而不是含「在飞字节」的统计值 ——
        // 后者会把还没落盘的字节算进去，重试时进度会先涨后跌。
        let segments = plannedSegments[id] ?? []
        let onDisk = DownloadStorage.totalPartSize(
            segments: segments,
            in: DownloadStorage.partsDirectory(for: id)
        )

        if onDisk > 0 {
            record.receivedBytes = onDisk
        }

        clearTransferStats(for: id)
        appState.updateDownload(record)

        LogStore.shared.error("failed \(record.displayFilename): \(message)")
    }

    /// 记录一次任务结束（完成或保存失败）。
    private func logCompletion(_ record: DownloadRecord) {
        if record.status == .finished {
            LogStore.shared.info("finished \(record.displayFilename) · \(TransferStats.formattedSize(record.receivedBytes ?? 0))")
        } else if let message = record.errorMessage {
            LogStore.shared.error("failed \(record.displayFilename): \(message)")
        }
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
                self.resetScheduling(for: id)
                self.releaseSlot(id)
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