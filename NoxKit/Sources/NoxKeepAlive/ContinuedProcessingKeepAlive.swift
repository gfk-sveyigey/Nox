import BackgroundTasks
import Foundation
import UIKit
import NoxCore

/// iOS 26 的持续后台处理。
///
/// 只有用户在前台发起下载时才能提交；提交后即使 App 进入后台，系统也会
/// 继续给进程执行时间，并在系统界面里显示进度与取消入口。
/// 对 HLS 分片编排、合并等“必须让 App 进程继续跑”的任务，比静音音频更正规。
@MainActor
public enum ContinuedProcessingBridge {
    public static let identifier = "com.aholic.nox.continued-processing"

    public static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    public static func registerIfNeeded() {
        if #available(iOS 26.0, *) {
            ContinuedProcessingKeepAlive.shared.registerIfNeeded()
        }
    }

    static var isLive: Bool {
        if #available(iOS 26.0, *) {
            return ContinuedProcessingKeepAlive.shared.isLive
        }
        return false
    }

    static var onInterruption: (() -> Void)? {
        get {
            if #available(iOS 26.0, *) {
                return ContinuedProcessingKeepAlive.shared.onInterruption
            }
            return nil
        }
        set {
            if #available(iOS 26.0, *) {
                ContinuedProcessingKeepAlive.shared.onInterruption = newValue
            }
        }
    }

    static func start() throws {
        guard #available(iOS 26.0, *) else {
            throw KeepAliveError.unsupported(L("持续处理"))
        }
        try ContinuedProcessingKeepAlive.shared.start()
    }

    static func stop() {
        if #available(iOS 26.0, *) {
            ContinuedProcessingKeepAlive.shared.stop()
        }
    }

    static func updateProgress(_ fraction: Double) {
        if #available(iOS 26.0, *) {
            ContinuedProcessingKeepAlive.shared.updateProgress(fraction)
        }
    }
}

@available(iOS 26.0, *)
@MainActor
private final class ContinuedProcessingKeepAlive {
    static let shared = ContinuedProcessingKeepAlive()

    var onInterruption: (() -> Void)?

    private(set) var isLive = false
    private var didRegister = false
    private var task: BGContinuedProcessingTask?
    private var heartbeat: Task<Void, Never>?
    private var progressFraction: Double = 0

    private init() {}

    func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ContinuedProcessingBridge.identifier,
            using: nil
        ) { [weak self] backgroundTask in
            guard let self,
                  let task = backgroundTask as? BGContinuedProcessingTask else {
                backgroundTask.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self.handle(task)
            }
        }
    }

    func start() throws {
        registerIfNeeded()
        guard isLive == false else { return }
        guard didRegister else {
            throw KeepAliveError.unavailable(L("持续处理"))
        }
        guard UIApplication.shared.applicationState == .active else {
            throw KeepAliveError.unavailable(L("持续处理"))
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: ContinuedProcessingBridge.identifier,
            title: L("正在下载"),
            subtitle: L("后台继续处理下载任务")
        )
        request.strategy = .queue

        do {
            try BGTaskScheduler.shared.submit(request)
            isLive = true
            LogStore.shared.info("continued processing submitted")
        } catch {
            throw KeepAliveError.unavailable(
                String(format: L("持续处理提交失败：%@"), error.localizedDescription)
            )
        }
    }

    func stop() {
        guard isLive || task != nil else { return }
        isLive = false
        heartbeat?.cancel()
        heartbeat = nil

        if let task {
            task.setTaskCompleted(success: true)
            self.task = nil
        } else {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: ContinuedProcessingBridge.identifier
            )
        }
        LogStore.shared.info("continued processing stopped")
    }

    func updateProgress(_ fraction: Double) {
        progressFraction = min(max(fraction, 0), 1)
        guard let task else { return }
        task.progress.completedUnitCount = progressUnits
        task.updateTitle(
            task.title,
            subtitle: String(format: "%d%%", Int(progressFraction * 100))
        )
    }

    private var progressUnits: Int64 {
        Int64((progressFraction * 1000).rounded())
    }

    private func handle(_ task: BGContinuedProcessingTask) {
        guard isLive else {
            task.setTaskCompleted(success: false)
            return
        }

        self.task = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = progressUnits
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.expire()
            }
        }

        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self, weak task] in
            while self?.isLive == true, !Task.isCancelled {
                if let task {
                    task.progress.completedUnitCount = self?.progressUnits ?? 0
                }
                try? await Task.sleep(for: .seconds(1))
            }

            guard let self, self.isLive else { return }
            task?.setTaskCompleted(success: true)
            self.task = nil
            self.isLive = false
        }
        LogStore.shared.info("continued processing started")
    }

    private func expire() {
        guard isLive else { return }
        isLive = false
        heartbeat?.cancel()
        heartbeat = nil
        task?.setTaskCompleted(success: false)
        task = nil
        LogStore.shared.warning("continued processing expired")
        onInterruption?()
    }
}
