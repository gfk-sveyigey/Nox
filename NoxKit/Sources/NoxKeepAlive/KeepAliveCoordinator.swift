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

    /// 当前实际生效的保活方式（跨模块只读入口）。
    public var currentMode: KeepAliveMode {
        activeMode
    }

    /// 当前实际生效保活方式的变化。Live Activity 用它判断何时让位给
    /// 系统为「持续处理」自动展示的活动。
    public var modePublisher: AnyPublisher<KeepAliveMode, Never> {
        $activeMode.eraseToAnyPublisher()
    }

    /// 用户偏好的保活方式。
    public var preferredMode: KeepAliveMode = .off {
        didSet {
            // iOS 26 以下不存在持续处理；即使旧配置或备份里残留了这个值，
            // 也不能让设置页出现一个当前系统无法执行的选项。
            guard preferredMode.isAvailable else {
                if preferredMode != .pictureInPicture {
                    preferredMode = .pictureInPicture
                }
                return
            }
            fallbackMode = nil
            reconcile()
        }
    }

    /// 主保活方式被系统打断后，是否允许自动降级到静音音频。
    ///
    /// 默认关闭：静音音频会占用音频会话，可能打断用户正在播放的内容，
    /// 必须由用户在设置页明确授权。
    public var allowsSilentAudioFallback = false {
        didSet {
            guard allowsSilentAudioFallback != oldValue else { return }
            if !allowsSilentAudioFallback {
                fallbackMode = nil
            }
            reconcile()
        }
    }

    /// 保活失效且仍有任务时是否发送本地通知。
    public var notificationsEnabled = false

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

    /// 是否输出所有后台方式的详细诊断日志（日志页全局开关）。
    public var verboseLogging = false {
        didSet {
            guard verboseLogging != oldValue else { return }
            pictureInPicture.verboseLogging = verboseLogging
            onLog?("[diagnostics] verbose=\(verboseLogging)")
        }
    }

    /// 诊断信息出口，接到 App 日志。
    public var onLog: ((String) -> Void)?
    /// 保活无法维持且未降级恢复时通知下载管理器暂停前台会话任务。
    public var onInterruption: (() -> Void)?

    /// 所有后台方式共用的详细诊断日志。
    private func verboseLog(_ message: @autoclosure () -> String) {
        guard verboseLogging else { return }
        onLog?("[keepalive.diag] \(message())")
    }

    private func logTransition(_ event: String, detail: String? = nil) {
        let suffix = detail.map { " · \($0)" } ?? ""
        onLog?("[keepalive] \(event) · preferred=\(preferredMode.rawValue) active=\(activeMode.rawValue) " +
               "needed=\(keepAliveNeeded) tasks=\(hasActiveTasks) app=\(Self.applicationStateDescription)\(suffix)")
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
    /// 当前临时的降级策略；回到前台或用户切换偏好后清除。
    private var fallbackMode: KeepAliveMode?
    private var lastNotificationAt = Date.distantPast

    /// 保活模式：跟随下载任务（默认）/ 启动即常驻。改动后立刻重新调度。
    public var lifetime: KeepAliveLifetime = .followTasks {
        didSet {
            guard lifetime != oldValue else { return }
            reconcile()
        }
    }

    /// 是否需要保活：常驻模式恒为真；跟随模式看是否有「排队中 / 下载中」的任务。
    ///
    /// 持续处理是系统按“用户发起的一项工作”授予的执行时间，没有下载任务时
    /// 不应该常驻，否则会浪费系统预算，也更容易被系统终止。
    private var keepAliveNeeded: Bool {
        guard preferredMode.startsKeepAlive else { return false }
        if targetMode == .continuedProcessing { return hasActiveTasks }
        return hasActiveTasks || lifetime == .alwaysOn
    }

    private var targetMode: KeepAliveMode {
        fallbackMode ?? preferredMode
    }

    public init() {
        pictureInPicture.coexistenceFallback = piPCoexistenceFallback
        pictureInPicture.windowHeight = pipWindowHeight
        pictureInPicture.verboseLogging = verboseLogging
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
            Task { @MainActor in self?.onLog?("[keepalive.pip] \(message)") }
        }
        ContinuedProcessingBridge.onInterruption = { [weak self] in
            Task { @MainActor in self?.handleInterruption() }
        }
    }

    /// 启动屏 / 冷启动阶段的准备工作。
    ///
    /// 画中画需要在有窗口时提前建立宿主视图与 controller；这里不启动悬浮窗，
    /// 只把基础设施准备好。系统后台任务的注册随后在 AppDelegate 里完成。
    public func prepareForLaunch() {
        ContinuedProcessingBridge.registerIfNeeded()

        if preferredMode == .pictureInPicture {
            onLog?("启动准备：预建画中画基础设施")
            pictureInPicture.prepare()
        }
    }

    /// 下载任务活跃数是否大于 0。
    public func update(hasActiveTasks: Bool) {
        if hasActiveTasks != self.hasActiveTasks {
            self.hasActiveTasks = hasActiveTasks
            logTransition("tasks changed")
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
        guard preferredMode.startsKeepAlive, keepAliveNeeded else { return }
        logTransition("retry requested")
        verboseLog("retryKeepAlive · preferred=\(preferredMode.title) active=\(activeMode.title) strategyRunning=\(activeStrategyIsRunning)")
        reconcile()
    }

    /// 回到前台时若保活已经掉了（系统结束 / 用户关闭了 PiP），重新建立。
    ///
    /// 这里检查的是策略的**真实存活状态**而不是我们自己的 `activeMode` 记录：
    /// App 在后台被挂起时，PiP 的结束回调可能不会送达，`activeMode` 会停留在旧值，
    /// 只看记录就会漏掉「其实已经掉了」的情况。
    public func didEnterForeground() {
        verboseLog("foreground · needed=\(keepAliveNeeded) preferred=\(preferredMode.rawValue) active=\(activeMode.rawValue) strategyRunning=\(activeStrategyIsRunning) app=\(Self.applicationStateDescription)")
        // 回到前台后重新优先尝试用户选择的策略，而不是一直停留在静音音频降级。
        let wasUsingFallback = fallbackMode != nil
        fallbackMode = nil
        guard keepAliveNeeded, preferredMode.startsKeepAlive else { return }
        guard wasUsingFallback || !activeStrategyIsRunning else { return }
        logTransition("foreground recovery", detail: "fallback=\(wasUsingFallback) strategyRunning=\(activeStrategyIsRunning)")
        activeMode = .off
        reconcile()
    }

    /// 当前生效的保活策略是否真的还在运行。
    private var activeStrategyIsRunning: Bool {
        switch activeMode {
        case .off, .foregroundOnly: return false
        case .continuedProcessing: return ContinuedProcessingBridge.isLive
        case .silentAudio: return silentAudio.isLive
        case .pictureInPicture: return pictureInPicture.isLive
        }
    }

    /// 把下载进度同步给持续处理任务，让系统知道任务仍在推进。
    public func updateProgress(_ fraction: Double) {
        guard activeMode == .continuedProcessing else { return }
        ContinuedProcessingBridge.updateProgress(fraction)
    }

    // MARK: - 内部

    private func reconcile() {
        verboseLog("reconcile · preferred=\(preferredMode.rawValue) active=\(activeMode.rawValue) needed=\(keepAliveNeeded) tasks=\(hasActiveTasks) lifetime=\(lifetime.rawValue) strategyRunning=\(activeStrategyIsRunning)")
        // 用户把保活方式关掉：彻底销毁画中画基础设施（宿主视图 + 会话）。
        if !preferredMode.startsKeepAlive {
            deactivate()
            pictureInPicture.invalidate()
            return
        }
        // 只是「暂时没有活跃任务」：停掉画中画，但**保留**会话与宿主视图，
        // 这样紧接着的「继续」可以直接复用现有会话 —— 刚停就重建几乎必被系统拒绝。
        guard keepAliveNeeded else {
            fallbackMode = nil
            deactivate()
            return
        }
        // 记录里的保活方式可能已经掉了（系统结束 / 启动失败 / 之前拿不到宿主窗口），
        // 但 `activeMode` 还停留在旧值 —— 那样 `activate` 会被 `guard activeMode != mode`
        // 挡掉，表现就是「继续/重试任务时拉不起保活」。这里按真实存活状态纠正一次。
        if activeMode != .off, !activeStrategyIsRunning {
            activeMode = .off
        }
        activate(targetMode)
    }

    private func activate(_ mode: KeepAliveMode) {
        verboseLog("activate · target=\(mode.title) current=\(activeMode.title) running=\(isRunning(mode)) needed=\(keepAliveNeeded) app=\(Self.applicationStateDescription)")
        guard mode.isAvailable else {
            lastError = String(format: L("%@ 在当前设备上不可用"), mode.title)
            logTransition("mode unavailable", detail: "target=\(mode.rawValue)")
            if mode == .continuedProcessing {
                fallbackMode = nil
                activate(.pictureInPicture)
            }
            return
        }
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
            logTransition("mode already running", detail: "target=\(mode.rawValue)")
            verboseLog("activate 仅同步状态：\(mode.title) 本来就在运行")
            return
        }

        // 画中画只有 App 真正前台激活时才能启动：冷启动阶段 `applicationState` 还是
        // `.inactive`（`DownloadManager` 在 init 里同步设置保活模式就会走到这里），
        // 此时 `startPictureInPicture()` 会被系统以 `AVKitErrorDomain -1001` 拒绝 ——
        // 表现就是「拉起画中画失败」。这里直接推迟，等 `didEnterForeground()` 再拉起。
        if mode == .pictureInPicture || mode == .continuedProcessing,
           UIApplication.shared.applicationState != .active {
            logTransition("start deferred", detail: "target=\(mode.rawValue) reason=app-not-active")
            verboseLog("start deferred · waiting for foreground")
            return
        }

        stopAll()
        do {
            switch mode {
            case .off, .foregroundOnly:
                break
            case .continuedProcessing:
                try ContinuedProcessingBridge.start()
            case .silentAudio:
                try silentAudio.start()
            case .pictureInPicture:
                try pictureInPicture.start()
            }
            activeMode = mode
            lastError = nil
            logTransition("mode start requested", detail: "target=\(mode.rawValue)")
            verboseLog("activate 成功：\(mode.title)")
        } catch {
            lastError = error.localizedDescription
            logTransition("mode start failed", detail: "target=\(mode.rawValue) error=\(error.localizedDescription)")
            verboseLog("activate 失败：\(error) preferred=\(preferredMode.title) fallback=\(piPCoexistenceFallback.title)")
            activeMode = .off
            // 共存保护不可用时按用户选的兜底方案处理；其余失败就停在这一档，
            // 不再自动改用别的保活方式（静音音频会打断用户正在播放的其它音频）。
            var handled = false
            if mode == .pictureInPicture,
               (error as? KeepAliveError)?.isCoexistenceUnavailable == true,
               piPCoexistenceFallback == .silentAudio {
                activate(.silentAudio)
                handled = true
            }
            if !handled, mode != .silentAudio, allowsSilentAudioFallback {
                fallbackMode = .silentAudio
                logTransition("fallback selected", detail: "target=\(KeepAliveMode.silentAudio.rawValue)")
                activate(.silentAudio)
                handled = true
            }
            if !handled {
                fallbackMode = nil
                reportInterruption()
            }
        }
    }

    private func deactivate() {
        if activeMode != .off || activeStrategyIsRunning {
            logTransition("mode stop requested", detail: "previous=\(activeMode.rawValue)")
        }
        stopAll()
        activeMode = .off
    }

    private func stopAll() {
        ContinuedProcessingBridge.stop()
        if silentAudio.isActive { silentAudio.stop() }
        // 以真实显示状态兜底：启动/停止竞态下 isActive 可能已经是 false，
        // 但系统窗口仍然弹了出来。
        if pictureInPicture.isActive || pictureInPicture.isDisplaying {
            pictureInPicture.stop()
        }
    }

    /// 策略是否真的还在运行（画中画把「正在建立中」也算活着）。
    private func isRunning(_ mode: KeepAliveMode) -> Bool {
        switch mode {
        case .off, .foregroundOnly: return false
        case .continuedProcessing: return ContinuedProcessingBridge.isLive
        case .silentAudio: return silentAudio.isLive
        case .pictureInPicture: return pictureInPicture.isLive
        }
    }

    /// 只停掉除 `mode` 以外的策略。
    private func stopOthers(than mode: KeepAliveMode) {
        if mode != .continuedProcessing { ContinuedProcessingBridge.stop() }
        if mode != .silentAudio, silentAudio.isActive { silentAudio.stop() }
        if mode != .pictureInPicture,
           pictureInPicture.isActive || pictureInPicture.isDisplaying {
            pictureInPicture.stop()
        }
    }

    private func handleInterruption() {
        verboseLog("interruption received · active=\(activeMode.rawValue) needed=\(keepAliveNeeded) preferred=\(preferredMode.rawValue)")
        guard keepAliveNeeded, preferredMode.startsKeepAlive else { return }
        let interrupted = activeMode
        stopAll()
        activeMode = .off

        // 静音音频被来电等打断后可以重试；但画中画或持续处理失效时，
        // 只有用户显式开启降级才切到静音音频，避免未经允许打断其他音频。
        if interrupted == .silentAudio {
            activate(.silentAudio)
            return
        }

        if allowsSilentAudioFallback {
            fallbackMode = .silentAudio
            logTransition("interruption fallback", detail: "target=\(KeepAliveMode.silentAudio.rawValue)")
            activate(.silentAudio)
            return
        }

        logTransition("interrupted; recovery deferred to foreground")
        reportInterruption()
    }

    /// 画中画「始终没能启动」（不是启动后被系统/用户结束）。
    ///
    /// 常见于其他 App 已有画中画、系统拒绝新建。这里不自动重试，
    /// 只停止并等待用户回到前台再重建（见 `didEnterForeground()`）。
    private func handleStartFailure() {
        verboseLog("start failure callback · active=\(activeMode.rawValue) needed=\(keepAliveNeeded) preferred=\(preferredMode.rawValue)")
        guard keepAliveNeeded, preferredMode.startsKeepAlive else { return }
        stopAll()
        activeMode = .off
        if allowsSilentAudioFallback {
            fallbackMode = .silentAudio
            logTransition("start failure fallback", detail: "target=\(KeepAliveMode.silentAudio.rawValue)")
            activate(.silentAudio)
            return
        }
        // 不做自动重试：等用户回到前台由 `didEnterForeground()` 重建。
        logTransition("start failed; recovery deferred to foreground")
        reportInterruption()
    }

    private func reportInterruption() {
        onInterruption?()
        notifyInterruptionIfNeeded()
    }

    private func notifyInterruptionIfNeeded() {
        guard notificationsEnabled, hasActiveTasks else { return }
        let now = Date()
        guard now.timeIntervalSince(lastNotificationAt) >= 60 else { return }
        lastNotificationAt = now
        Task { await KeepAliveNotifier.notifyInterrupted() }
    }
}
