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
    /// 每个任务当前这一次下载尝试的令牌。
    ///
    /// 暂停 / 删除 / 重试会让旧令牌失效；旧 run 的探测、网络回调或合并流程
    /// 即使晚到，也只能看到「令牌不匹配」然后退出，不会再改状态、抢槽位，
    /// 或把新 run 的结果覆盖掉。
    var runTokens: [UUID: UUID] = [:]
    /// 正在拼接分片的任务（按 run 令牌记录）。同一任务重试后可以重新合并，
    /// 不会被上一次尚未退出的合并流程永久卡住。
    var assemblingTokens = Set<UUID>()
    /// 每个任务一个速度估算器；取代原先的「逐帧瞬时值 + 指数平滑」。
    var speedMeters: [UUID: SpeedMeter] = [:]
    var progressTimer: Timer?

    /// 后台保活：有活跃下载时启动，全部结束 / 取消时停止。
    let keepAlive: KeepAliveCoordinator
    var keepAliveObservation: AnyCancellable?
    /// 下载记录状态变化的兜底观察：任何状态迁移都会触发一次队列对齐。
    var recordObservation: AnyCancellable?
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
    ///
    /// 正在探测、下载、合并分片的都算占一个槽位；完成 / 失败 / 暂停 / 删除
    /// 会立即释放。调小上限不会打断正在跑的任务，只会暂时停止补位，
    /// 等 active 数自然降到新上限以下后再继续取队列。
    var maxConcurrentTasks: Int {
        let configured = store.maxConcurrentDownloads

        // 「无限制」用 0 表示：上限取 Int.max，队列有多少就跑多少。
        guard configured != NoxDefaults.unlimitedConcurrentDownloads else { return .max }

        return max(1, configured)
    }

    /// 当前设置是否允许下载请求使用蜂窝网络。
    ///
    /// 除了建会话时的配置，每个请求还会单独带一次 `allowsCellularAccess`：
    /// 设置可以随时改，而已有的 `URLSession` 不会重建（重建会取消在跑的任务）。
    var allowsCellularDownloads: Bool {
        store.downloadNetworkMode.allowsCellularAccess
    }

    /// 已占用槽位的任务（探测中 / 下载中 / HLS 合并中）
    var activeIDs = Set<UUID>()
    /// 排队等待槽位的任务，先进先出
    var pendingQueue: [UUID] = []
    /// 每个任务的调度句柄；取消它会一路中止其内部的 async 工作
    var slotTasks: [UUID: Task<Void, Never>] = [:]
    /// 防止状态变更回调重入调度器
    var isReconcilingQueue = false

    /// 清理缓存时必须保留的分片 / 暂存目录。
    ///
    /// 不只依赖 activeIDs：`status` 是唯一事实来源，排队中的任务也要保留，
    /// 否则 App 重启后队列还没补位时清缓存会把它们的分片删掉。
    var protectedDownloadIDs: Set<UUID> {
        var ids = activeIDs
        for record in store.downloads where record.status == .queued || record.status == .downloading {
            ids.insert(record.id)
        }
        return ids
    }

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
        /// 创建这个分片请求时所属的 run；用于丢弃重试前旧请求的迟到回调。
        let runToken: UUID
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
        // 会话级兜底；设置切换后由每个请求上的同名字段接管。
        configuration.allowsCellularAccess = allowsCellularDownloads
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

        // 状态变化兜底：正常完成、失败、暂停、删除、重试、调大上限等都会
        // 改变「排队 / 下载中」集合。无论变化来自哪条代码路径，这里都会在
        // 当前 runloop 结束后对齐一次队列，避免漏掉补位。
        //
        // `@Published` 在属性写入前发出新值，所以必须异步执行，等 `store.downloads`
        // 真正更新后再调度。进度刷新不会改变状态集合，会被 removeDuplicates 过滤。
        recordObservation = store.downloadsPublisher
            .map { records in
                records
                    .filter { $0.status == .queued || $0.status == .downloading }
                    .map { "\($0.id.uuidString):\($0.status.rawValue)" }
                    .sorted()
            }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.reconcileTaskQueue(reason: "records")
                }
            }

        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.keepAlive.didEnterForeground()
                self?.reconcileTaskQueue(reason: "active")
            }
        }

        // 上次进程被杀时可能留下了 .queued 任务。启动后按持久化状态恢复队列，
        // 否则它们会永远停在“排队中”。
        reconcileTaskQueue(reason: "launch")
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

    /// 让任务队列与当前下载记录重新对齐。
    ///
    /// 设置页调整「同时下载任务数」、App 回到前台后调用，保证空闲槽位能
    /// 立刻被排队任务补上。
    public func reconcileQueue() {
        reconcileTaskQueue(reason: "manual")
    }

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
        guard let live = store.downloads.first(where: { $0.id == record.id }),
              live.status == .failed || live.status == .cancelled else {
            return
        }

        // 先让旧 run 失效，再改成排队状态。否则旧 run 的迟到回调可能把
        // 新一次尝试又标成失败 / 取消，或者抢走刚分配的槽位。
        invalidateRun(for: live.id)
        resetScheduling(for: live.id)
        clearTransferStats(for: live.id)
        removeFromQueue(live.id)
        releaseSlotWithoutPump(live.id)

        var updated = live
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
        // 完成 / 失败的任务可能刚好在用户点按前结束，不能把终态又改成已取消。
        guard let live = store.downloads.first(where: { $0.id == record.id }),
              live.status == .queued || live.status == .downloading else {
            return
        }

        performCancel(live)
        reconcileTaskQueue(reason: "cancel")
        LogStore.shared.info("cancel \(live.displayFilename)")

        // 取消后保留历史记录：取消只是想停下来，不代表这次访问没发生过。
        // 真正要清掉历史时，用下载页 / 历史页的「清空」或左滑删除。
    }

    /// 只修改单个任务的状态并释放槽位；多个任务批量暂停时由调用方统一
    /// `reconcileTaskQueue`，避免每暂停一个就把后面的排队任务拉起来一次。
    private func performCancel(_ record: DownloadRecord) {
        // 先让当前 run 失效：之后的探测结果、分片回调、合并结果都不会再写状态。
        invalidateRun(for: record.id)

        // 还在排队就直接出队，否则槽位空出来时它会莫名其妙地开始下载
        removeFromQueue(record.id)

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
        releaseSlotWithoutPump(record.id)
    }

    /// 批量暂停（多选时用）。只处理排队中 / 下载中的任务。
    ///
    /// 暂停复用 `cancel`：已下载分片留在磁盘上，状态记为 `.cancelled`，
    /// 之后可以「继续下载」。先快照再处理，避免边遍历边修改 downloads。
    public func cancelAll(ids: Set<UUID>) {
        let targets = store.downloads.filter {
            ids.contains($0.id) && ($0.status == .queued || $0.status == .downloading)
        }

        for record in targets {
            performCancel(record)
        }
        reconcileTaskQueue(reason: "cancel batch")
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
        reconcileTaskQueue(reason: "clear")
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
        performDelete(record)
        refreshMissingFiles()
        reconcileTaskQueue(reason: "delete")
    }

    /// 批量删除（多选时用）。先快照再删，避免边遍历边修改 downloads。
    public func deleteFiles(ids: Set<UUID>) {
        let targets = store.downloads.filter { ids.contains($0.id) }

        for record in targets {
            performDelete(record)
        }
        refreshMissingFiles()
        reconcileTaskQueue(reason: "delete batch")
    }

    /// 删除文件和记录，但不主动补位；由调用方在整批删除完成后统一调度，
    /// 避免删到一半时把还在选中列表里的排队任务提前拉起来。
    private func performDelete(_ record: DownloadRecord) {
        deleteLocalArtifacts(for: record)
        store.removeDownload(record)
    }

    func deleteLocalArtifacts(for record: DownloadRecord) {
        // 先停掉可能还在跑的调度任务与网络请求，再删文件，
        // 否则删完文件后请求回调仍会往分片目录写。
        invalidateRun(for: record.id)

        if let url = shareableFileURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        } else if let url = record.fileURL, url.isFileURL {
            try? FileManager.default.removeItem(at: url)
        }

        try? FileManager.default.removeItem(at: DownloadStorage.partsDirectory(for: record.id))
        try? FileManager.default.removeItem(at: DownloadStorage.stagingDirectory(for: record.id))

        resetScheduling(for: record.id)
        clearTransferStats(for: record.id)
        removeFromQueue(record.id)
        releaseSlotWithoutPump(record.id)
    }
}
