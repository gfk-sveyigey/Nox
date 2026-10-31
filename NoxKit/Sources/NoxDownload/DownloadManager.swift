import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

@MainActor
public final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    /// 下载中的实时统计（已下载 / 总大小 / 速度），仅内存。
    @Published public internal(set) var transfers: [UUID: TransferStats] = [:]

    /// 状态是「已完成」但本地文件已经不在了的记录（启动时扫描发现）。
    /// 列表据此提示「文件缺失」，并隐藏分享入口。
    @Published public private(set) var missingFileIDs: Set<UUID> = []

    /// 每个分片的目标大小。
    ///
    /// 必须是**固定值**：分片边界只由 (总大小, 本值) 决定，与线程数无关。
    /// 之前按「线程数」切分，导致关闭多线程时整个文件只有 1 个分片 ——
    /// 分片未下完前不会落盘，于是取消/失败等于进度全丢。
    static let segmentLength: Int64 = 4 * 1024 * 1024

    let store: DownloadStateStore
    var cancellingIDs = Set<UUID>()
    /// 正在拼接分片的任务。合并要读写整份文件、可能持续很久，
    /// 期间若被再次触发就会各写一份成品 —— 表现为「同一任务冒出多个大小/时长不同的文件」。
    var assemblingIDs = Set<UUID>()
    /// 每个任务一个速度估算器；取代原先的「逐帧瞬时值 + 指数平滑」。
    var speedMeters: [UUID: SpeedMeter] = [:]
    var progressTimer: Timer?

    /// 后台保活：有活跃下载时启动，全部结束 / 取消时停止。
    let keepAlive: KeepAliveCoordinator
    var keepAliveObservation: AnyCancellable?
    /// App 真正激活的系统通知。
    ///
    /// 冷启动 / 弹窗切换时 SwiftUI 的 `scenePhase` 不一定每次都走 `.active`，用它兜底：
    /// 任何因为「App 尚未进入前台」而被推迟的保活启动，都会在这里补上。
    var becomeActiveObserver: NSObjectProtocol?

    // MARK: - 全局并发调度

    /// 同时进行的**任务**数上限。
    ///
    /// 这是任务数而不是连接数：每个任务内部还会开若干分片连接，
    /// 实际连接总数 ≈ 本值 × 单任务并发。
    var maxConcurrentTasks: Int {
        let configured = store.maxConcurrentDownloads

        // 「无限制」用 0 表示：上限取 Int.max，队列有多少就跑多少。
        guard configured != NoxDefaults.unlimitedConcurrentDownloads else { return .max }

        return max(1, configured)
    }

    /// 已占用槽位的任务（探测中 / 下载中 / HLS 合并中）
    var activeIDs = Set<UUID>()
    /// 排队等待槽位的任务，先进先出
    var pendingQueue: [UUID] = []
    /// 每个任务的调度句柄；取消它会一路中止其内部的 async 工作
    var slotTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - 单任务内的分片调度

    /// 待下载的分片下标（FIFO）。用显式队列而不是一次性起全部 task，
    /// 才能让「并发数」真正生效。
    var pendingSegments: [UUID: [Int]] = [:]
    /// 当前在飞的分片数
    var inFlightSegments: [UUID: Int] = [:]
    /// 该任务启动时快照下来的并发上限
    var recordConcurrency: [UUID: Int] = [:]
    /// HLS 最近一次上报的进度；速度统一由 1 秒定时器计算，避免分片成批完成时抖动
    var hlsProgress: [UUID: HLSDownloader.Progress] = [:]

    /// key = task.taskIdentifier
    var contexts: [Int: SegmentContext] = [:]
    /// 每个任务当前规划的分片
    var plannedSegments: [UUID: [DownloadSegment]] = [:]
    /// 本次会话内确认完成的分片下标
    var completedSegments: [UUID: Set<Int>] = [:]

    struct SegmentContext {
        let recordID: UUID
        let segmentIndex: Int
        let partURL: URL
        let alreadyWritten: Int64
        let task: URLSessionDownloadTask
    }

    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.aholic.nox.downloads"
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        // 允许多线程设置最大到 32 条并发连接
        configuration.httpMaximumConnectionsPerHost = NoxDefaults.segmentCountRange.upperBound
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }()

    public init(store: DownloadStateStore) {
        self.store = store
        keepAlive = KeepAliveCoordinator()
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

        keepAlive.onLog = { message in LogStore.shared.info(message) }
        keepAlive.piPVerboseLogging = store.pipVerboseLogging
        keepAlive.preferredMode = store.keepAliveMode
        keepAlive.piPCoexistenceFallback = store.pipCoexistenceFallback
        keepAlive.lifetime = store.keepAliveLifetime
        keepAlive.pipWindowHeight = store.pipWindowHeight

        // 用下载记录的「排队中 / 下载中」驱动保活启停。
        // 直接订阅 `downloads`，而不是在每个状态迁移点手写调用：漏一处就会出现
        // 「任务已经全部结束，保活却还开着」的情况。
        keepAliveObservation = store.downloadsPublisher
            .map { $0.contains { $0.status == .queued || $0.status == .downloading } }
            .removeDuplicates()
            .sink { [weak self] hasActive in
                Task { @MainActor in
                    self?.keepAlive.update(hasActiveTasks: hasActive)
                }
            }

        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.keepAlive.didEnterForeground() }
        }
    }

    deinit {
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
        }
    }

    /// 重新扫描「已完成但文件缺失」的记录。
    public func refreshMissingFiles() {
        var missing = Set<UUID>()

        for record in store.downloads where record.status == .finished {
            if shareableFileURL(for: record) == nil {
                missing.insert(record.id)
            }
        }

        missingFileIDs = missing

        if !missing.isEmpty {
            LogStore.shared.warning("missing files: \(missing.count)")
        }
    }

    /// 设置页切换保活方式。
    public func setKeepAliveMode(_ mode: KeepAliveMode) {
        store.keepAliveMode = mode
        store.persist()
        keepAlive.preferredMode = mode
    }

    /// 设置页选择「画中画共存保护不可用」时的兜底方案。
    public func setPiPCoexistenceFallback(_ fallback: PiPCoexistenceFallback) {
        store.pipCoexistenceFallback = fallback
        store.persist()
        keepAlive.piPCoexistenceFallback = fallback
    }

    /// 设置页切换「保活模式」（跟随下载任务 / 启动即常驻）。
    public func setKeepAliveLifetime(_ lifetime: KeepAliveLifetime) {
        store.keepAliveLifetime = lifetime
        store.persist()
        keepAlive.lifetime = lifetime
    }

    /// 设置页调节「画中画窗口大小」（高度，pt）。
    public func setPiPWindowHeight(_ height: Double) {
        store.pipWindowHeight = height
        store.persist()
        keepAlive.pipWindowHeight = height
    }

    /// 设置页切换「画中画详细日志」。
    public func setPiPVerboseLogging(_ enabled: Bool) {
        store.pipVerboseLogging = enabled
        store.persist()
        keepAlive.piPVerboseLogging = enabled
    }

    // MARK: - 对外接口

    public func enqueue(
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

        store.addDownload(record)

        // 历史在这里（真正入队下载时）记录，而不是解析时：
        // 解析了但没下载、或下载被取消，都不该在历史里留下痕迹。
        // 历史标题用文件名（去扩展名），而不是页面标题。
        store.addHistory(title: record.displayTitle, url: referer ?? record.sourceURL)

        LogStore.shared.info("enqueue \(record.displayFilename) [\(record.quality)/\(record.format)] <- \(referer?.absoluteString ?? record.sourceURL.absoluteString)")

        start(record)
    }

    /// 供「选择文件名」弹窗预填：按 `title-quality.ext` 生成，并避开 Documents 里的同名文件。
    public func suggestedFilename(title: String, quality: String, format: String) -> String {
        let ext = Self.fileExtension(for: format)
        return Self.uniqueFilename("\(title)-\(quality).\(ext)")
    }

    /// 重试即「继续」：已下载的分片会保留，从断点开始。
    public func retry(_ record: DownloadRecord) {
        guard record.status == .failed || record.status == .cancelled else {
            return
        }

        var updated = record
        updated.status = .queued
        updated.errorMessage = nil
        updated.fileName = nil
        updated.fileURL = nil
        // 保留 totalBytes / segmentCount / receivedBytes / progress，start 时会用磁盘上的分片重新校准

        store.updateDownload(updated)

        // 取消后历史会保留，这里只是把它重新排到最前（addHistory 按页面去重）。
        store.addHistory(title: updated.displayTitle, url: updated.refererURL ?? updated.sourceURL)
        LogStore.shared.info("retry \(updated.displayFilename)")

        // 重新开始：丢弃旧采样，速度从头累积。
        speedMeters[updated.id] = nil

        start(updated)

        // 取消任务会顺手停掉保活；「继续」时补一次重建检查 ——
        // 刚停就重启很容易被系统拒绝，必须主动再试一次，而不是等状态变化。
        keepAlive.retryKeepAlive()
    }

    /// 批量重试（多选时用）
    public func retryAll(ids: Set<UUID>) {
        for record in store.downloads where ids.contains(record.id) {
            retry(record)
        }
    }

    public func cancel(_ record: DownloadRecord) {
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
        store.updateDownload(updated)
        releaseSlot(record.id)

        LogStore.shared.info("cancel \(updated.displayFilename)")

        // 取消后保留历史记录：取消只是想停下来，不代表这次访问没发生过。
        // 真正要清掉历史时，用下载页 / 历史页的「清空」或左滑删除。
    }

    /// 清空：删除记录 + 本地文件 + 未完成的分片。
    public func clearFinished() {
        let removable = store.downloads.filter {
            $0.status == .finished ||
            $0.status == .failed ||
            $0.status == .cancelled
        }

        for record in removable {
            deleteLocalArtifacts(for: record)
        }

        store.clearFinishedDownloads()
        refreshMissingFiles()
    }

    public func shareableFileURL(for record: DownloadRecord) -> URL? {
        let directory = DownloadStorage.documentsDirectory

        let candidates: [URL] = [
            record.fileName.map { directory.appendingPathComponent($0) },
            record.fileURL.map { directory.appendingPathComponent($0.lastPathComponent) }
        ].compactMap { $0 }

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    public func deleteFile(for record: DownloadRecord) {
        deleteLocalArtifacts(for: record)
        store.removeDownload(record)
        refreshMissingFiles()
    }

    /// 批量删除（多选时用）。先快照再删，避免边遍历边修改 downloads。
    public func deleteFiles(ids: Set<UUID>) {
        let targets = store.downloads.filter { ids.contains($0.id) }

        for record in targets {
            deleteFile(for: record)
        }
    }

    func deleteLocalArtifacts(for record: DownloadRecord) {
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
}
