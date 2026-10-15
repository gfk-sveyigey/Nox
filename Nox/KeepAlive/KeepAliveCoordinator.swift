import Foundation
import Combine

/// 保活调度：按「保活模式」决定何时启动 —— 跟随下载任务（有活跃任务才启动）
/// 或启动即常驻；任务全部结束 / 取消（跟随模式下）时停止。
///
/// 失败或被打断时**不会**自动切换到别的保活方式（避免静默改用会打断其它音频的
/// 静音音频），也不会自动重试，只记录原因；回到前台由 `didEnterForeground()` 重建。
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

    /// 画中画窗口高度（pt）。
    ///
    /// 只把尺寸变化即时应用到正在运行的画中画，**不重建会话**：
    /// 刚停掉就立刻重启常被系统拒绝，会让保活直接失效。
    var pipWindowHeight: Double = AppState.defaultPiPWindowHeight {
        didSet {
            guard pipWindowHeight != oldValue else { return }
            pictureInPicture.windowHeight = pipWindowHeight
        }
    }

    /// 诊断信息出口，接到 App 日志。
    var onLog: ((String) -> Void)?

    private let silentAudio = SilentAudioKeepAlive()
    private let pictureInPicture = PictureInPictureKeepAlive()
    private var hasActiveTasks = false

    /// 保活模式：跟随下载任务（默认）/ 启动即常驻。改动后立刻重新调度。
    var lifetime: KeepAliveLifetime = .followTasks {
        didSet {
            guard lifetime != oldValue else { return }
            reconcile()
        }
    }

    /// 是否需要保活：常驻模式恒为真；跟随模式看是否有「排队中 / 下载中」的任务。
    private var keepAliveNeeded: Bool { hasActiveTasks || lifetime == .alwaysOn }

    init() {
        pictureInPicture.coexistenceFallback = piPCoexistenceFallback
        pictureInPicture.windowHeight = pipWindowHeight
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
        reconcile()
    }

    /// 回到前台时若保活已经掉了（系统结束 / 用户关闭了 PiP），重新建立。
    ///
    /// 这里检查的是策略的**真实存活状态**而不是我们自己的 `activeMode` 记录：
    /// App 在后台被挂起时，PiP 的结束回调可能不会送达，`activeMode` 会停留在旧值，
    /// 只看记录就会漏掉「其实已经掉了」的情况。
    func didEnterForeground() {
        guard keepAliveNeeded, preferredMode != .off else { return }
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
        guard keepAliveNeeded, preferredMode != .off else {
            deactivate()
            return
        }
        // 记录里的保活方式可能已经掉了（系统结束 / 启动失败 / 之前拿不到宿主窗口），
        // 但 `activeMode` 还停留在旧值 —— 那样 `activate` 会被 `guard activeMode != mode`
        // 挡掉，表现就是「继续/重试任务时拉不起保活」。这里按真实存活状态纠正一次。
        if activeMode != .off, !activeStrategyIsRunning {
            activeMode = .off
        }
        activate(preferredMode)
    }

    private func activate(_ mode: KeepAliveMode) {
        guard activeMode != mode else { return }

        // 目标策略其实还在运行（例如系统结束回调没送达、记录停在了 `.off`）：
        // 只纠正记录、停掉另一个策略，**不**「停掉再立刻重启」——
        // 画中画刚停就重启几乎必被系统拒绝，表现就是「拉不起保活」。
        if isRunning(mode) {
            stopOthers(than: mode)
            activeMode = mode
            lastError = nil
            return
        }

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

    /// 策略是否真的还在运行（画中画把「正在建立中」也算活着）。
    private func isRunning(_ mode: KeepAliveMode) -> Bool {
        switch mode {
        case .off: return false
        case .silentAudio: return silentAudio.isLive
        case .pictureInPicture: return pictureInPicture.isLive
        }
    }

    /// 只停掉除 `mode` 以外的策略。
    private func stopOthers(than mode: KeepAliveMode) {
        if mode != .silentAudio, silentAudio.isActive { silentAudio.stop() }
        if mode != .pictureInPicture, pictureInPicture.isActive { pictureInPicture.stop() }
    }

    private func handleInterruption() {
        guard keepAliveNeeded, preferredMode != .off else { return }
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
    /// 常见于其他 App 已有画中画、系统拒绝新建。这里不自动重试，
    /// 只停止并等待用户回到前台再重建（见 `didEnterForeground()`）。
    private func handleStartFailure() {
        guard keepAliveNeeded, preferredMode != .off else { return }
        stopAll()
        activeMode = .off
        // 不做自动重试：等用户回到前台由 `didEnterForeground()` 重建。
        onLog?("保活中断，将在回到前台后重建")
    }
}
