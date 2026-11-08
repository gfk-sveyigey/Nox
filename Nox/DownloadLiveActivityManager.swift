import ActivityKit
import Combine
import Foundation
import UIKit
import NoxActivity
import NoxCore
import NoxDownload
import NoxState

/// 把下载状态投射到锁屏 / 灵动岛的 Live Activity。
///
/// 与保活方式解耦：系统下载、仅前台、静音音频、画中画都使用这里创建的活动；
/// 持续处理默认由系统展示自己的活动；用户可在通知设置中允许同时显示自定义活动。
@MainActor
final class DownloadLiveActivityManager {
    private let appState: AppState
    private let downloadManager: DownloadManager

    private var cancellables = Set<AnyCancellable>()
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastState: DownloadActivityAttributes.ContentState?
    private var lastUpdateAt = Date.distantPast
    /// 结束旧活动的清理任务；新建活动前要先等它完成，
    /// 否则旧的 ended / stale 活动仍会和新的抢灵动岛。
    private var cleanupTask: Task<Void, Never>?
    private var cleaningIDs = Set<String>()
    private var startupTask: Task<Void, Never>?
    /// 进度定时器每秒刷新一次；Live Activity 合并到约 1 秒一次，
    /// 既不会错过保活方式的进度变化，也不会因过密更新被系统节流。
    private static let minimumUpdateInterval: TimeInterval = 1.0
    /// 后台更新受系统调度，长时间无回调时将活动标记为过期；
    /// 锁屏卡片会展示最后一次更新时间，明确区分旧快照与实时进度。
    private static let staleInterval: TimeInterval = 3600
    /// 系统最多让一个活动活跃 8 小时，到点会强制结束并立刻从灵动岛移除，
    /// 但锁屏上还会再留最多 4 小时。提前一点换成新活动，避免出现
    /// 「锁屏有、灵动岛没有」的残留。
    private static let maximumActivityAge: TimeInterval = 8 * 3600 - 300

    init(appState: AppState, downloadManager: DownloadManager) {
        self.appState = appState
        self.downloadManager = downloadManager
        bind()
        refresh(force: true)
    }

    private func bind() {
        let downloads = appState.$downloads
            .map { _ in () }
            .eraseToAnyPublisher()

        let managerChanges = downloadManager.objectWillChange
            .map { _ in () }
            .eraseToAnyPublisher()

        let modeChanges = downloadManager.activeKeepAliveModePublisher
            .map { _ in () }
            .eraseToAnyPublisher()

        // 用 throttle 而不是 debounce：第一次变化立即处理，避免用户点了下载
        // 马上切走 / 锁定（尤其画中画启动会让 App 状态变化）时错过
        // 「只能在前台创建」的窗口；后续变化仍然合并到约 4 次/秒。
        downloads
            .merge(with: managerChanges)
            .merge(with: modeChanges)
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                Task { @MainActor in self?.refresh(force: false) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh(force: true) }
            }
            .store(in: &cancellables)

        // 进入后台前做一次最终同步；之后能否继续更新取决于保活方式。
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh(force: true) }
            }
            .store(in: &cancellables)

        // 设置页关闭自定义灵动岛 / 实时活动后，立即结束现有活动；
        // 重新打开时，若仍有下载任务会在前台重新创建。
        appState.$customLiveActivityEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh(force: true) }
            }
            .store(in: &cancellables)

        appState.$customLiveActivityDuringContinuedProcessing
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh(force: true) }
            }
            .store(in: &cancellables)
    }

    private func refresh(force: Bool) {
        reconcileExistingActivityIfNeeded()

        guard appState.customLiveActivityEnabled else {
            endActivity(using: lastState)
            return
        }

        guard let state = makeState() else {
            endActivity(using: lastState)
            return
        }

        // 持续处理时默认让位给系统活动；只有用户开启低优先级的并显开关才叠加。
        // 如果系统任务启动失败（activeMode 仍是 .off），仍显示自定义活动。
        guard downloadManager.activeKeepAliveMode != .continuedProcessing
                || appState.customLiveActivityDuringContinuedProcessing else {
            endActivity(using: state)
            return
        }

        if activity == nil {
            // Activity.request 只能在 App 前台发起。`.inactive` 仍属于前台
            // （例如画中画启动、切换 App 的瞬间），也允许尝试；真正的
            // `.background` 只能等下一次进入前台再开始展示。
            guard canRequestActivity else { return }
            startActivity(with: state)
        } else {
            updateActivity(with: state, force: force)
        }
    }

    /// 让内存里的活动记录与系统里真实存在的活动对齐。
    ///
    /// 锁屏会保留已经结束 / stale 的活动，而灵动岛只展示仍在活跃的那个；
    /// 如果系统里还残留旧活动，并且 relevance 相同，灵动岛会优先展示
    /// 「最早开始」的那一个。异常退出、重复启动都可能留下这种残留，
    /// 表现就是「锁屏有实时活动，灵动岛没有」。
    ///
    /// 因此这里只保留一个真正可用的活动：其余全部结束，没有可用的就
    /// 全部清掉，让刷新流程重新创建一个。
    private func reconcileExistingActivityIfNeeded() {
        let existing = Activity<DownloadActivityAttributes>.activities

        if let current = activity {
            let stillExists = existing.contains { $0.id == current.id }
            if !stillExists || !isUsable(current) {
                activity = nil
                lastState = nil
                lastUpdateAt = .distantPast
            }
        }

        if let current = activity {
            enqueueCleanup(existing.filter { $0.id != current.id })
            return
        }

        let usable = existing.filter { isUsable($0) }
        let obsolete = existing.filter { item in
            !usable.contains { $0.id == item.id }
        }

        if let adopted = usable.first {
            activity = adopted
            lastState = nil
            lastUpdateAt = .distantPast
            LogStore.shared.info(
                "live activity adopted · usable \(usable.count) · stale \(obsolete.count)"
            )
            enqueueCleanup(existing.filter { $0.id != adopted.id })
        } else {
            enqueueCleanup(obsolete)
        }
    }

    private func isUsable(_ activity: Activity<DownloadActivityAttributes>) -> Bool {
        guard activity.activityState == .active else { return false }
        return Date().timeIntervalSince(activity.attributes.startedAt)
            < Self.maximumActivityAge
    }

    /// 串行结束旧活动。新建活动会等待这里完成，避免同类型活动在系统里
    /// 同时存在时灵动岛挑中旧的那个。
    private func enqueueCleanup(_ activities: [Activity<DownloadActivityAttributes>]) {
        let scheduled = activities.filter { cleaningIDs.insert($0.id).inserted }
        guard !scheduled.isEmpty else { return }
        LogStore.shared.info("live activity cleanup · ending \(scheduled.count)")

        let previous = cleanupTask
        cleanupTask = Task { @MainActor [scheduled] in
            await previous?.value
            for item in scheduled {
                await item.end(nil, dismissalPolicy: .immediate)
                self.cleaningIDs.remove(item.id)
            }
        }
    }

    private func makeState() -> DownloadActivityAttributes.ContentState? {
        let active = appState.downloads.filter {
            $0.status == .queued || $0.status == .downloading
        }
        guard !active.isEmpty else { return nil }

        let downloading = active.filter { $0.status == .downloading }
        let knownSize = active.filter { ($0.totalBytes ?? 0) > 0 }

        let progress: Double
        if knownSize.isEmpty {
            progress = active.reduce(0) { partial, record in
                partial + min(max(record.progress, 0), 1)
            } / Double(active.count)
        } else {
            let totalBytes = knownSize.reduce(Int64(0)) {
                $0 + max($1.totalBytes ?? 0, 0)
            }
            let completed = knownSize.reduce(Double(0)) { partial, record in
                let value = min(max(record.progress, 0), 1)
                return partial + value * Double(max(record.totalBytes ?? 0, 0))
            }
            progress = totalBytes > 0 ? completed / Double(totalBytes) : 0
        }

        let activeIDs = Set(active.map(\.id))
        let speed = downloadManager.transfers
            .filter { activeIDs.contains($0.key) }
            .values
            .reduce(Double(0)) { $0 + max($1.bytesPerSecond, 0) }

        let current = downloading.first ?? active.first
        let title = appState.showsTaskNames
            ? (current?.displayTitle ?? "Nox")
            : L("正在下载")

        return DownloadActivityAttributes.ContentState(
            progress: progress,
            activeCount: active.count,
            downloadingCount: downloading.count,
            bytesPerSecond: speed,
            currentTitle: title
        )
    }

    private func startActivity(with state: DownloadActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard startupTask == nil else { return }

        // 先等旧活动清理完再请求新活动；等的时候 App 可能已经进入后台，
        // 或任务已经结束，所以请求前重新检查一遍状态。
        let cleanup = cleanupTask
        startupTask = Task { @MainActor [weak self] in
            await cleanup?.value
            guard let self else { return }
            self.startupTask = nil
            guard self.activity == nil,
                  self.canRequestActivity,
                  self.downloadManager.activeKeepAliveMode != .continuedProcessing,
                  let latest = self.makeState() else { return }
            self.requestActivity(with: latest)
        }
    }

    private var canRequestActivity: Bool {
        UIApplication.shared.applicationState != .background
    }

    private func requestActivity(with state: DownloadActivityAttributes.ContentState) {
        do {
            activity = try Activity.request(
                attributes: DownloadActivityAttributes(startedAt: .now),
                content: ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(Self.staleInterval),
                    relevanceScore: 100
                ),
                pushType: nil
            )
            lastState = state
            lastUpdateAt = .now
            LogStore.shared.info(
                "live activity started · app=\(UIApplication.shared.applicationState.rawValue)"
            )
        } catch {
            LogStore.shared.warning(
                "live activity start failed · \(error.localizedDescription)"
            )
        }
    }

    private func updateActivity(
        with state: DownloadActivityAttributes.ContentState,
        force: Bool
    ) {
        guard let activity else { return }

        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastUpdateAt) >= Self.minimumUpdateInterval else {
                return
            }
            if let lastState,
               abs(lastState.progress - state.progress) < 0.001,
               lastState.activeCount == state.activeCount,
               lastState.downloadingCount == state.downloadingCount,
               abs(lastState.bytesPerSecond - state.bytesPerSecond) < 1,
               lastState.currentTitle == state.currentTitle {
                return
            }
        }

        lastState = state
        lastUpdateAt = now
        let content = ActivityContent(
            state: state,
            staleDate: now.addingTimeInterval(Self.staleInterval),
            relevanceScore: 100
        )
        Task { await activity.update(content) }
    }

    private func endActivity(using state: DownloadActivityAttributes.ContentState?) {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        lastUpdateAt = .distantPast

        let content = state.map {
            ActivityContent<DownloadActivityAttributes.ContentState>(
                state: $0,
                staleDate: nil
            )
        }
        Task {
            await activity.end(
                content,
                dismissalPolicy: .after(Date().addingTimeInterval(3))
            )
        }
        LogStore.shared.info("live activity ended")
    }
}
