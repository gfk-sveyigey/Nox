import Foundation
import Combine
import UIKit
import NoxCore

/// 保活调度：按「保活模式」决定何时启动 —— 跟随下载任务（有活跃任务才启动）
/// 或启动即常驻；任务全部结束 / 取消（跟随模式下）时停止。
///
/// 失败或被打断时**不会**自动切换到别的保活方式（避免静默改用会打断其它音频的
/// 静音音频），也不会自动重试，只记录原因；回到前台由 `didEnterForeground()` 重建。
@MainActor
public final class KeepAliveCoordinator: ObservableObject {

    /// 当前实际生效的保活方式（可能因降级与偏好不同）。
    @Published private(set) var activeMode: KeepAliveMode = .off
    /// 最近一次失败原因，用于设置页提示。
    @Published private(set) var lastError: String?

    /// 用户偏好的保活方式。
    public var preferredMode: KeepAliveMode = .off {
        didSet { reconcile() }
    }

    /// 画中画共存保护不可用时用户选择的兜底方案。
    public var piPCoexistenceFallback: PiPCoexistenceFallback = .keepAlive {
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
    public var pipWindowHeight: Double = NoxDefaults.defaultPiPWindowHeight {
        didSet {
            guard pipWindowHeight != oldValue else { return }
            pictureInPicture.windowHeight = pipWindowHeight
        }
    }

    /// 是否输出画中画详细诊断日志（设置页开关）。
    public var piPVerboseLogging = false {
        didSet {
            guard piPVerboseLogging != oldValue else { return }
            pictureInPicture.verboseLogging = piPVerboseLogging
            onLog?("画中画详细日志已\(piPVerboseLogging ? "开启" : "关闭")")
        }
    }

    /// 诊断信息出口，接到 App 日志。
    public var onLog: ((String) -> Void)?

    /// 详细诊断日志（只在画中画相关时输出）。
    private func verboseLog(_ message: @autoclosure () -> String) {
        guard piPVerboseLogging,
              preferredMode == .pictureInPicture || activeMode == .pictureInPicture else { return }
        onLog?("保活诊断：\(message())")
    }

    private static var applicationStateDescription: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default:
            return "unknown(\(UIApplication.shared.applicationState.rawValue))"
        }
    }

    private let silentAudio = SilentAudioKeepAlive()
    private let pictureInPicture = PictureInPictureKeepAlive()
    private var hasActiveTasks = false

    /// 保活模式：跟随下载任务（默认）/ 启动即常驻。改动后立刻重新调度。
    public var lifetime: KeepAliveLifetime = .followTasks {
        didSet {
            guard lifetime != oldValue else { return }
            reconcile()
        }
    }

    /// 是否需要保活：常驻模式恒为真；跟随模式看是否有「排队中 / 下载中」的任务。
    private var keepAliveNeeded: Bool { hasActiveTasks || lifetime == .alwaysOn }

    public init() {
        pictureInPicture.coexistenceFallback = piPCoexistenceFallback
        pictureInPicture.windowHeight = pipWindowHeight
        pictureInPicture.verboseLogging = piPVerboseLogging
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
    public func update(hasActiveTasks: Bool) {
        if hasActiveTasks != self.hasActiveTasks {
            self.hasActiveTasks = hasActiveTasks
            onLog?("有活跃下载任务：\(hasActiveTasks)")
        }
        // 即使活跃数没变也过一遍 reconcile：保活可能已经在别的路径上掉了
        // （启动被拒 / 被系统结束），只等「状态变化」是等不到重建的。
        verboseLog("update · hasActiveTasks=\(hasActiveTasks) needed=\(keepAliveNeeded) preferred=\(preferredMode.title) active=\(activeMode.title) lifetime=\(lifetime.title)")
        reconcile()
    }

    /// 用户主动「继续 / 重试」任务时调用：立即重新检查一次保活。
    ///
    /// 「继续」不一定改变 `hasActiveTasks`（比如本来就还有别的任务在跑），而画中画
    /// 很可能已经因为启动被拒 / 被系统结束而掉了 —— 这里补一次确定性的重建。
    public func retryKeepAlive() {
        guard preferredMode != .off, keepAliveNeeded else { return }
        onLog?("用户继续任务，重新检查保活")
        verboseLog("retryKeepAlive · preferred=\(preferredMode.title) active=\(activeMode.title) strategyRunning=\(activeStrategyIsRunning)")
        reconcile()
    }

    /// 回到前台时若保活已经掉了（系统结束 / 用户关闭了 PiP），重新建立。
    ///
    /// 这里检查的是策略的**真实存活状态**而不是我们自己的 `activeMode` 记录：
    /// App 在后台被挂起时，PiP 的结束回调可能不会送达，`activeMode` 会停留在旧值，
    /// 只看记录就会漏掉「其实已经掉了」的情况。
    public func didEnterForeground() {
        verboseLog("didEnterForeground · needed=\(keepAliveNeeded) preferred=\(preferredMode.title) active=\(activeMode.title) strategyRunning=\(activeStrategyIsRunning) app=\(Self.applicationStateDescription)")
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
        verboseLog("reconcile · preferred=\(preferredMode.title) active=\(activeMode.title) needed=\(keepAliveNeeded) hasActiveTasks=\(hasActiveTasks) lifetime=\(lifetime.title) strategyRunning=\(activeStrategyIsRunning)")
        // 用户把保活方式关掉：彻底销毁画中画基础设施（宿主视图 + 会话）。
        if preferredMode == .off {
            deactivate()
            pictureInPicture.invalidate()
            return
        }
        // 只是「暂时没有活跃任务」：停掉画中画，但**保留**会话与宿主视图，
        // 这样紧接着的「继续」可以直接复用现有会话 —— 刚停就重建几乎必被系统拒绝。
        guard keepAliveNeeded else {
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
        verboseLog("activate · target=\(mode.title) current=\(activeMode.title) running=\(isRunning(mode)) needed=\(keepAliveNeeded) app=\(Self.applicationStateDescription)")
        guard activeMode != mode else {
            verboseLog("activate 跳过：当前已是 \(mode.title)")
            return
        }

        // 目标策略其实还在运行（例如系统结束回调没送达、记录停在了 `.off`）：
        // 只纠正记录、停掉另一个策略，**不**「停掉再立刻重启」——
        // 画中画刚停就重启几乎必被系统拒绝，表现就是「拉不起保活」。
        if isRunning(mode) {
            stopOthers(than: mode)
            activeMode = mode
            lastError = nil
            onLog?("保活已在运行，仅同步状态：\(mode.title)")
            verboseLog("activate 仅同步状态：\(mode.title) 本来就在运行")
            return
        }

        // 画中画只有 App 真正前台激活时才能启动：冷启动阶段 `applicationState` 还是
        // `.inactive`（`DownloadManager` 在 init 里同步设置保活模式就会走到这里），
        // 此时 `startPictureInPicture()` 会被系统以 `AVKitErrorDomain -1001` 拒绝 ——
        // 表现就是「拉起画中画失败」。这里直接推迟，等 `didEnterForeground()` 再拉起。
        if mode == .pictureInPicture, UIApplication.shared.applicationState != .active {
            onLog?("保活启动推迟：App 尚未进入前台")
            verboseLog("启动推迟：app=\(Self.applicationStateDescription)，等待 didEnterForeground")
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
            verboseLog("activate 成功：\(mode.title)")
        } catch {
            lastError = error.localizedDescription
            onLog?("保活启动失败：\(error.localizedDescription)")
            verboseLog("activate 失败：\(error) preferred=\(preferredMode.title) fallback=\(piPCoexistenceFallback.title)")
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
        verboseLog("deactivate · before active=\(activeMode.title) needed=\(keepAliveNeeded)")
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
        verboseLog("handleInterruption · active=\(activeMode.title) needed=\(keepAliveNeeded) preferred=\(preferredMode.title)")
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
        verboseLog("handleStartFailure · active=\(activeMode.title) needed=\(keepAliveNeeded) preferred=\(preferredMode.title)")
        guard keepAliveNeeded, preferredMode != .off else { return }
        stopAll()
        activeMode = .off
        // 不做自动重试：等用户回到前台由 `didEnterForeground()` 重建。
        onLog?("保活中断，将在回到前台后重建")
    }
}
