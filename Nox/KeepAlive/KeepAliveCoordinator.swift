import Foundation
import Combine
import UIKit

/// 保活调度：有活跃下载时启动、全部结束 / 取消时停止。
///
/// 失败或被打断时**不会**自动切换到别的保活方式（避免静默改用会打断其它音频的
/// 静音音频），只记录原因，回到前台由 `didEnterForeground()` 重建。
@MainActor
final class KeepAliveCoordinator: ObservableObject {

    /// 当前实际生效的保活方式（可能因降级与偏好不同）。
    @Published private(set) var activeMode: KeepAliveMode = .off
    /// 最近一次失败原因，用于设置页提示。
    @Published private(set) var lastError: String?

    /// 用户偏好的保活方式。
    var preferredMode: KeepAliveMode = .off {
        didSet { reconcile() }
    }

    /// 画中画共存保护不可用时用户选择的兜底方案。
    var piPCoexistenceFallback: PiPCoexistenceFallback = .keepAlive {
        didSet {
            pictureInPicture.coexistenceFallback = piPCoexistenceFallback
            if activeMode == .pictureInPicture, pictureInPicture.isActive,
               !pictureInPicture.isCoexistenceInstalled, piPCoexistenceFallback != .keepAlive {
                // 用户把「继续用画中画」改成了别的，而当前这档并无共存保护：按新选择重建。
                deactivate()
                reconcile()
            }
        }
    }

    /// 是否以最小化（视觉隐藏）方式显示画中画。
    ///
    /// 只把尺寸变化即时应用到正在运行的画中画，**不重建会话**：
    /// 刚停掉就立刻重启常被系统拒绝，会让保活直接失效。
    var pipMinimized: Bool = true {
        didSet {
            guard pipMinimized != oldValue else { return }
            pictureInPicture.isMinimized = pipMinimized
        }
    }

    /// 诊断信息出口，接到 App 日志。
    var onLog: ((String) -> Void)?

    private let silentAudio = SilentAudioKeepAlive()
    private let pictureInPicture = PictureInPictureKeepAlive()
    private var hasActiveTasks = false

    /// 前台自动重试（保活被中断后，不必等回到前台再手动重建）。
    private var retryTask: Task<Void, Never>?
    private var foregroundRetryCount = 0
    private static let maxForegroundRetries = 4
    private static let foregroundRetryDelay: Duration = .seconds(5)

    init() {
        pictureInPicture.coexistenceFallback = piPCoexistenceFallback
        pictureInPicture.isMinimized = pipMinimized
        // 回调可能来自非主线程（音频中断通知等），显式跳回主线程再改状态。
        silentAudio.onInterruption = { [weak self] in
            Task { @MainActor in self?.handleInterruption() }
        }
        pictureInPicture.onInterruption = { [weak self] in
            Task { @MainActor in self?.handleInterruption() }
        }
        pictureInPicture.onStartFailure = { [weak self] in
            Task { @MainActor in self?.handleStartFailure() }
        }
        pictureInPicture.onLog = { [weak self] message in
            Task { @MainActor in self?.onLog?(message) }
        }
    }

    /// 下载任务活跃数是否大于 0。
    func update(hasActiveTasks: Bool) {
        guard hasActiveTasks != self.hasActiveTasks else { return }
        self.hasActiveTasks = hasActiveTasks
        if hasActiveTasks { foregroundRetryCount = 0 }
        reconcile()
    }

    /// 回到前台时若保活已经掉了（系统结束 / 用户关闭了 PiP），重新建立。
    ///
    /// 这里检查的是策略的**真实存活状态**而不是我们自己的 `activeMode` 记录：
    /// App 在后台被挂起时，PiP 的结束回调可能不会送达，`activeMode` 会停留在旧值，
    /// 只看记录就会漏掉「其实已经掉了」的情况。
    func didEnterForeground() {
        guard hasActiveTasks, preferredMode != .off else { return }
        foregroundRetryCount = 0
        guard !activeStrategyIsRunning else { return }
        activeMode = .off
        reconcile()
    }

    /// 当前生效的保活策略是否真的还在运行。
    private var activeStrategyIsRunning: Bool {
        switch activeMode {
        case .off: return false
        case .silentAudio: return silentAudio.isLive
        case .pictureInPicture: return pictureInPicture.isLive
        }
    }

    // MARK: - 内部

    private func reconcile() {
        guard hasActiveTasks, preferredMode != .off else {
            deactivate()
            return
        }
        activate(preferredMode)
    }

    private func activate(_ mode: KeepAliveMode) {
        guard activeMode != mode else { return }
        stopAll()
        do {
            switch mode {
            case .off:
                break
            case .silentAudio:
                try silentAudio.start()
            case .pictureInPicture:
                try pictureInPicture.start()
            }
            activeMode = mode
            lastError = nil
            onLog?("保活已启动：\(mode.title)")
        } catch {
            lastError = error.localizedDescription
            onLog?("保活启动失败：\(error.localizedDescription)")
            activeMode = .off
            // 共存保护不可用时按用户选的兜底方案处理；其余失败就停在这一档，
            // 不再自动改用别的保活方式（静音音频会打断用户正在播放的其它音频）。
            if mode == .pictureInPicture,
               (error as? KeepAliveError)?.isCoexistenceUnavailable == true,
               piPCoexistenceFallback == .silentAudio {
                activate(.silentAudio)
            }
        }
    }

    private func deactivate() {
        stopAll()
        activeMode = .off
    }

    private func stopAll() {
        if silentAudio.isActive { silentAudio.stop() }
        if pictureInPicture.isActive { pictureInPicture.stop() }
    }

    private func handleInterruption() {
        guard hasActiveTasks, preferredMode != .off else { return }
        let interrupted = activeMode
        stopAll()
        activeMode = .off
        // 画中画被系统 / 用户结束：**不要**自动改用静音音频
        // （那会打断用户正在听的其他音频）。
        // 静音音频被打断（来电等）结束后，则按用户原本的选择重试。
        if interrupted == .silentAudio, preferredMode == .silentAudio {
            activate(.silentAudio)
        } else {
            onLog?("保活中断，将在回到前台后重建")
        }
    }

    /// 画中画「始终没能启动」（不是启动后被系统/用户结束）。
    ///
    /// 常见于其他 App 已有画中画、系统拒绝新建；此时在前台做有限次延迟重试，
    /// 不必等用户切后台再切回来。次数有上限，不做无限重启循环。
    private func handleStartFailure() {
        guard hasActiveTasks, preferredMode != .off else { return }
        stopAll()
        activeMode = .off
        scheduleForegroundRetry()
    }

    /// 前台有限重试：只在前台、仍有活跃任务、且没超过次数上限时重试。
    private func scheduleForegroundRetry() {
        guard hasActiveTasks, preferredMode != .off else { return }
        guard UIApplication.shared.applicationState == .active else {
            onLog?("保活中断，将在回到前台后重建")
            return
        }
        guard foregroundRetryCount < Self.maxForegroundRetries else {
            onLog?("保活已中断且重试次数用尽，将在回到前台后重建")
            return
        }
        foregroundRetryCount += 1
        onLog?("保活中断，将在 \(Self.foregroundRetryDelay) 后重试（第 \(foregroundRetryCount) 次）")
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.foregroundRetryDelay)
            guard let self, !Task.isCancelled else { return }
            guard self.hasActiveTasks, self.preferredMode != .off else { return }
            self.activeMode = .off
            self.reconcile()
        }
    }
}
