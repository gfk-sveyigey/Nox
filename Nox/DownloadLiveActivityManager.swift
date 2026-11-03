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
/// 持续处理则由系统自动展示它自己的活动，本类会主动结束自定义活动，
/// 避免出现两个进度界面。
@MainActor
final class DownloadLiveActivityManager {
    private let appState: AppState
    private let downloadManager: DownloadManager

    private var cancellables = Set<AnyCancellable>()
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastState: DownloadActivityAttributes.ContentState?
    private var lastUpdateAt = Date.distantPast
    private static let minimumUpdateInterval: TimeInterval = 1.5
    private static let staleInterval: TimeInterval = 120

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

        downloads
            .merge(with: managerChanges)
            .merge(with: modeChanges)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
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
    }

    private func refresh(force: Bool) {
        adoptExistingActivityIfNeeded()

        guard let state = makeState() else {
            endActivity(using: lastState)
            return
        }

        // iOS 26 持续处理会由系统展示自己的 Live Activity，不能再叠一个。
        // 冷启动时系统活动可能还没真正启动，因此配置为持续处理且当前尚未
        // 启用其它策略时也先让位，避免两个活动短暂并存。
        let activeMode = downloadManager.activeKeepAliveMode
        let preferredMode = downloadManager.preferredKeepAliveMode
        let willUseContinuedProcessing = activeMode == .continuedProcessing
            || (activeMode == .off && preferredMode == .continuedProcessing)
        guard !willUseContinuedProcessing else {
            endActivity(using: state)
            return
        }

        if activity == nil {
            // Activity.request 只能在 App 前台发起。后台恢复时若没有既有活动，
            // 只能等下一次进入前台再开始展示。
            guard UIApplication.shared.applicationState == .active else { return }
            startActivity(with: state)
        } else {
            updateActivity(with: state, force: force)
        }
    }

    private func adoptExistingActivityIfNeeded() {
        guard activity == nil else { return }

        let existing = Activity<DownloadActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        guard let adopted = existing.first else { return }

        activity = adopted
        // 后台恢复 / 旧版本异常退出可能留下多个同类型活动；
        // 只保留一个，其余立即结束，避免灵动岛叠出多张卡片。
        for extra in existing.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        LogStore.shared.info("live activity adopted")
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
            LogStore.shared.info("live activity started")
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
               abs(lastState.progress - state.progress) < 0.002,
               lastState.activeCount == state.activeCount,
               lastState.downloadingCount == state.downloadingCount {
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
