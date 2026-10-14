import Foundation
import Combine

/// 保活调度：有活跃下载时启动、全部结束 / 取消时停止，失败时按降级链回退。
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

    /// 诊断信息出口，接到 App 日志。
    var onLog: ((String) -> Void)?

    private let silentAudio = SilentAudioKeepAlive()
    private let pictureInPicture = PictureInPictureKeepAlive()
    private var hasActiveTasks = false

    init() {
        // 回调可能来自非主线程（音频中断通知等），显式跳回主线程再改状态。
        silentAudio.onInterruption = { [weak self] in
            Task { @MainActor in self?.handleInterruption() }
        }
        pictureInPicture.onInterruption = { [weak self] in
            Task { @MainActor in self?.handleInterruption() }
        }
        pictureInPicture.onLog = { [weak self] message in
            Task { @MainActor in self?.onLog?(message) }
        }
    }

    /// 下载任务活跃数是否大于 0。
    func update(hasActiveTasks: Bool) {
        guard hasActiveTasks != self.hasActiveTasks else { return }
        self.hasActiveTasks = hasActiveTasks
        reconcile()
    }

    /// 回到前台时若保活已经掉了（系统结束 / 用户关闭了 PiP），重新建立。
    ///
    /// 这里检查的是策略的**真实存活状态**而不是我们自己的 `activeMode` 记录：
    /// App 在后台被挂起时，PiP 的结束回调可能不会送达，`activeMode` 会停留在旧值，
    /// 只看记录就会漏掉「其实已经掉了」的情况。
    func didEnterForeground() {
        guard hasActiveTasks, preferredMode != .off else { return }
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
            // 降级链：PiP 失败 → 静音音频；静音音频失败 → 关闭。
            if mode == .pictureInPicture {
                activeMode = .off
                activate(.silentAudio)
            } else {
                activeMode = .off
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
        if activeMode == .pictureInPicture {
            // PiP 被关闭 / 启动失败 → 降级到静音音频。
            activeMode = .off
            activate(.silentAudio)
        } else {
            stopAll()
            activeMode = .off
            reconcile()
        }
    }
}
