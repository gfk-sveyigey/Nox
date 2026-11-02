import BackgroundTasks
import Foundation
import NoxCore
import NoxDownload

/// 系统调度的后台恢复任务。
///
/// `BGAppRefreshTask` 负责轻量队列检查，`BGProcessingTask` 负责较重的恢复与整理。
/// 两者都不是持续保活，只用于 App 被挂起或进程被回收后的兜底恢复。
@MainActor
final class BackgroundRecovery {
    static let shared = BackgroundRecovery()

    static let refreshIdentifier = "com.aholic.nox.refresh"
    static let processingIdentifier = "com.aholic.nox.processing"

    private var didRegister = false

    private init() {}

    /// 必须在 `application(_:didFinishLaunchingWithOptions:)` 返回前调用。
    func register() {
        guard !didRegister else { return }
        didRegister = true

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await Self.shared.handle(refreshTask, kind: .refresh)
            }
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await Self.shared.handle(processingTask, kind: .processing)
            }
        }
    }

    /// 根据当前是否有排队 / 下载中任务提交恢复请求。
    func schedule(hasActiveDownloads: Bool) {
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: Self.refreshIdentifier
        )
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: Self.processingIdentifier
        )

        guard hasActiveDownloads else { return }

        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        let processing = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(refresh)
            try BGTaskScheduler.shared.submit(processing)
            LogStore.shared.info("background recovery submitted")
        } catch {
            LogStore.shared.warning(
                "background recovery submit failed · \(error.localizedDescription)"
            )
        }
    }

    private enum Kind: Equatable {
        case refresh
        case processing
    }

    private func handle(_ task: BGTask, kind: Kind) async {
        LogStore.shared.info(
            kind == .refresh ? "background refresh started" : "background processing started"
        )

        let work = Task { @MainActor in
            let manager = AppServices.shared.downloadManager
            manager.performBackgroundRecovery()
            return manager.hasActiveDownloads
        }

        task.expirationHandler = {
            work.cancel()
        }

        let stillActive = await work.value
        let success = !work.isCancelled
        task.setTaskCompleted(success: success)
        schedule(hasActiveDownloads: stillActive && success)
    }
}
