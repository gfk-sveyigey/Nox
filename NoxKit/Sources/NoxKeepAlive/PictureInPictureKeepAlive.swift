import AVFoundation
import AVKit
import Foundation
import UIKit
import NoxCore

/// 画中画保活（VideoCall 路线）。
///
/// 与「挂一段视频循环播放」的 PlayerLayer 路线不同，这里用系统给通话场景提供的
/// `AVPictureInPictureVideoCallViewController` 承载一个**完全透明、高度压到 0.1pt** 的内容视图：
/// - 视觉上不可见，不影响用户操作；
/// - **不申请音频会话**，因此不会打断其他 App 正在播放的音乐 / 视频；
/// - 通过 `PiPCoexistenceProtection` 做共存保护，尽量避免与其他 App 的 PiP 互相挤掉。
///
/// 参考：GlobalRefresh-PiP 1.1.1 的「VideoCall + 仅 PiP 保活」组合（见 docs/DEVELOPMENT_PRD.md）。
@MainActor
final class PictureInPictureKeepAlive: NSObject, KeepAliveStrategy {

    let name = L("画中画 (PiP)")
    private(set) var isActive = false
    var onInterruption: (() -> Void)?
    /// 「始终没能启动」回调（区别于「启动后被系统/用户结束」）。
    var onStartFailure: (() -> Void)?

    /// 诊断信息出口（内部适配是否可用等），由协调器转接到日志。
    var onLog: ((String) -> Void)?

    /// 详细诊断日志开关（设置页）。只影响日志输出，不改变保活逻辑。
    var verboseLogging = false {
        didSet {
            guard verboseLogging != oldValue else { return }
            coexistence?.verboseLogging = verboseLogging
            if verboseLogging {
                verboseLog("详细日志已开启 · \(stateSummary)")
            }
        }
    }

    /// 一条便于排查的画中画状态摘要。
    private var stateSummary: String {
        let controllerState: String
        if let controller {
            controllerState = "possible=\(controller.isPictureInPicturePossible) " +
                "active=\(controller.isPictureInPictureActive) " +
                "suspended=\(controller.isPictureInPictureSuspended)"
        } else {
            controllerState = "controller=nil"
        }
        return "\(controllerState) startPending=\(isStartPending) activeFlag=\(isActive) " +
            "attempt=\(attemptCount) retry=\(startRetryCount) readyStreak=\(readyStreak) " +
            "app=\(Self.applicationStateDescription)"
    }

    private func verboseLog(_ message: @autoclosure () -> String) {
        guard verboseLogging else { return }
        onLog?("画中画诊断：\(message())")
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

    /// 当前场景 / 窗口概况，宿主窗口找不到时用来定位原因。
    private static func sceneSummary() -> String {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let parts = scenes.map { scene -> String in
            let windows = scene.windows.map { window -> String in
                "key=\(window.isKeyWindow) hidden=\(window.isHidden) bounds=\(window.bounds)"
            }
            return "activation=\(scene.activationState.rawValue) windows=[\(windows.joined(separator: "; "))]"
        }
        return "scenes=\(scenes.count) [\(parts.joined(separator: " | "))]"
    }

    /// 共存保护装不上时的处理方式，由协调器按用户在设置里选的值同步过来。
    ///
    /// `.keepAlive` 表示「暂缓启动，等保护就绪」，不是「无视保护强行启动」。
    var coexistenceFallback: PiPCoexistenceFallback = .keepAlive

    /// 画中画基础设施：controller / 内容控制器 / 宿主视图。
    ///
    /// ⚠️ 只建一次，**跨启停复用**，停止时只调 `stopPictureInPicture()`，不拆掉宿主视图。
    /// 原因：系统在「结束一个画中画会话」后的一小段时间内会拒绝新建，而把宿主视图从窗口里
    /// 摘掉、再把 controller 置空，会让这次会话以「不干净」的方式收尾（`AVKitErrorDomain -1001`）。
    /// 两者叠加就是「取消任务后再继续，画中画再也拉不起来」。参考实现 GlobalRefresh-PiP 同样是
    /// 整个 App 生命周期只建一次 controller，之后只做 start / stopPictureInPicture。
    private var controller: AVPictureInPictureController?
    private var contentController: AVPictureInPictureVideoCallViewController?
    private weak var sourceView: UIView?
    private var sourceWidth: NSLayoutConstraint?
    private var sourceHeight: NSLayoutConstraint?
    private var coexistence: PiPCoexistenceProtection?
    /// 这一次「停止」是我们自己发起的（任务结束 / 切保活方式），
    /// 用来把 `didStop` 和「用户或系统关掉了画中画」区分开。
    private var isStoppingSelf = false

    /// PiP 悬浮窗高度（pt），由设置页滑块调节。0 表示最小化：0.1pt，视觉隐藏。
    ///
    /// 改动时**不重建** PiP 会话：刚停掉就立刻重启常被系统拒绝，
    /// 会导致保活直接失效；这里只更新宿主视图尺寸并即时生效。
    var windowHeight: Double = NoxDefaults.defaultPiPWindowHeight {
        didSet {
            guard windowHeight != oldValue else { return }
            applySizeToRunningPiP()
        }
    }

    /// PiP 悬浮窗尺寸：宽度固定 300pt，高度由滑块决定；0 时压到 0.1pt（不可见）。
    private var pipSize: CGSize {
        let height = windowHeight < 1 ? NoxDefaults.minimizedPiPWindowHeight : windowHeight
        return CGSize(width: 300, height: height)
    }

    /// 启动后的「一次性」核对任务，确认 PiP 真的进入激活状态。
    private var startVerificationTask: Task<Void, Never>?
    /// 观察 `isPictureInPicturePossible`，就绪后再启动。
    private var possibleObservation: NSKeyValueObservation?

    /// 启动重试 / 抖动确认的统一任务。
    private var startTask: Task<Void, Never>?
    /// 停止后的核对任务：系统偶尔会忽略「启动尚未完成时」的停止请求。
    private var stopVerificationTask: Task<Void, Never>?
    /// 连续观察到 `isPictureInPicturePossible == true` 的次数（抖动确认用）。
    private var readyStreak = 0
    /// 已尝试启动的次数（`isPictureInPicturePossible` 一直 false 时的低速重试用）。
    private var attemptCount = 0
    /// 上一次停止 PiP 的时刻（单调时钟），用于「刚停就重启」冷却。
    private var lastStopUptime: TimeInterval?
    /// 是否已经调用过 `startPictureInPicture()`、正在等结果。
    ///
    /// 结果回来之前**绝不能**再调一次：重复调用会被系统以 `AVKitErrorDomain -1001`
    /// 拒绝，日志里就会同时出现两次「开始启动」和一次启动失败。
    private var isStartPending = false
    /// 启动 API 被系统拒绝 / 迟迟未激活时的重试计数（`didStart` 或重开会话时清零）。
    private var startRetryCount = 0
    /// 「等上一次停止收尾」的重试次数（见 `attemptStartIfPossible`）。
    private var stopWaitCount = 0
    /// 共存保护暂不可用、正在等待它就绪（此时**不会**启动 PiP）。
    private var isWaitingForCoexistence = false
    /// 等待共存保护的低频重试任务。
    private var coexistenceRetryTask: Task<Void, Never>?

    /// 抖动确认窗口：刚创建 controller 时 `isPictureInPicturePossible` 常是瞬时 true，
    /// 之后系统才算出真值。要求它连续三次为 true 才真正启动。
    ///
    /// 宁可多等约 1.6 秒，也不要拿一个瞬时 true 去启动 —— 那会直接把其他 App
    /// 正在播放的画中画挤掉。
    private static let startSettleDelay: Double = 0.8
    /// 启动前要求连续观察到「可启动」的次数。
    private static let requiredReadyStreak = 3
    /// 未就绪时的重试间隔。
    private static let startRetryDelay: Double = 0.8
    /// 未就绪时保持「快速重试」的次数上限；之后转入低速重试（**不会**放弃会话）。
    private static let maxFastStartAttempts = 5
    /// 转入低速重试后的间隔。
    private static let startSlowRetryDelay: Double = 3
    /// 每多少次未就绪上报一次日志，避免刷屏。
    private static let startAttemptsPerNotice = 10
    /// 启动 API 被拒 / 迟迟未激活时的重试次数上限；超过才真正上报失败。
    private static let maxStartRetries = 4
    /// 等上一次停止收尾的次数上限（≈ 6.4 秒）。
    private static let maxStopWaitAttempts = 8
    /// 共存保护暂不可用时的重试间隔。
    ///
    /// 多数情况是一次性失败（系统还没把 `playbackState` 准备好），隔一小段时间
    /// 重新安装即可；重试期间绝不调用 `startPictureInPicture()`，因此不会挤掉
    /// 其他 App 正在播放的画中画。
    private static let coexistenceRetryDelay: Double = 2
    /// 共存保护等待次数上限（约 30 秒）。超过后按「启动失败」交给协调器处理。
    private static let maxCoexistenceWaitAttempts = 15
    /// 启动后核对是否进入激活状态的延迟。
    ///
    /// 不能太短：核对失败会走重试链，把「只是慢了一点、马上就会激活」的会话当成失败。
    private static let startVerificationDelay: Double = 8
    /// 上一次停止 PiP 之后，允许再次启动的最短间隔（秒）。
    ///
    /// 系统在刚结束一个画中画会话后的一小段时间内会拒绝新建；
    /// 「先停再立刻起」几乎必失败，因此这里宁可推迟启动。
    private static let restartCooldown: TimeInterval = 2

    func start() throws {
        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        verboseLog("start 请求 · supported=\(supported) \(stateSummary) \(Self.sceneSummary())")

        guard supported else {
            throw KeepAliveError.unsupported(name)
        }

        let pipController = try ensureInfrastructure()
        verboseLog("基础设施就绪 · \(stateSummary)")

        stopVerificationTask?.cancel()
        stopVerificationTask = nil
        isActive = true
        readyStreak = 0
        attemptCount = 0
        startRetryCount = 0
        stopWaitCount = 0

        if pipController.isPictureInPictureActive {
            if isStoppingSelf {
                // 刚请求过停止、系统还在收尾：等它真的停掉再启动（收尾期间新建几乎必被拒）。
                onLog?("画中画正在收尾，稍后重试启动")
                verboseLog("start 时正在收尾 · \(stateSummary)")
                attemptStartIfPossible(pipController)
                return
            }
            // 会话其实还在运行：直接复用，绝不重复 start。
            isStartPending = false
            onLog?("画中画会话已在运行，复用现有会话")
            verboseLog("start 时会话已激活，复用 · \(stateSummary)")
            coexistence?.schedulePostStartUpdate(for: pipController)
            return
        }

        attemptStartIfPossible(pipController)
    }

    /// 启动屏期间预建基础设施，避免用户第一次真正需要保活时才现场创建。
    ///
    /// 只创建 controller / 宿主视图 / 共存保护，不调用 `startPictureInPicture()`，
    /// 所以不会出现悬浮窗，也不会打断其他 App。失败时保持静默，等真正启动时重试。
    func prepare() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard !canReuseInfrastructure else {
            verboseLog("启动屏准备：现有基础设施可复用 · \(stateSummary)")
            return
        }

        do {
            _ = try ensureInfrastructure()
            verboseLog("启动屏准备完成 · \(stateSummary)")
        } catch {
            onLog?("画中画启动屏准备失败：\(error.localizedDescription)")
            verboseLog("启动屏准备失败 · \(error) \(Self.sceneSummary())")
        }
    }

    /// 就近复用 / 新建画中画基础设施。
    ///
    /// 复用时会重新装一次共存保护：上一次停止时已经把内容类型退回 4，
    /// 需要重新走「首次 4 → 启动后 6」的流程。
    private func ensureInfrastructure() throws -> AVPictureInPictureController {
        if let existing = controller, canReuseInfrastructure {
            verboseLog("复用基础设施 · \(stateSummary) coexistenceInstalled=\(coexistence?.isSupported == true)")
            if let coexistence {
                coexistence.prepare()
                if !coexistence.isSupported, coexistenceFallback != .keepAlive {
                    onLog?("画中画共存保护不可用，按设置\(coexistenceFallback.title)")
                    destroyInfrastructure()
                    throw KeepAliveError.coexistenceUnavailable(name)
                }
            }
            return existing
        }

        if controller != nil {
            verboseLog("现有基础设施不可复用，销毁后重建 · \(stateSummary) sourceWindow=\(sourceView?.window != nil)")
        }
        destroyInfrastructure()
        return try makeInfrastructure()
    }

    /// 现有会话是否还能复用（宿主视图仍在某个窗口上）。
    private var canReuseInfrastructure: Bool {
        guard controller != nil else { return false }
        guard let view = sourceView, view.window != nil else { return false }
        return true
    }

    /// 建立画中画基础设施（宿主视图 + controller + 共存保护）。
    private func makeInfrastructure() throws -> AVPictureInPictureController {
        verboseLog("创建基础设施 · size=\(pipSize) \(Self.sceneSummary())")
        let host = try makeHostView()
        let content = AVPictureInPictureVideoCallViewController()
        content.preferredContentSize = pipSize
        content.view.backgroundColor = .clear
        content.view.isOpaque = false
        // 铺满一个透明子视图，保证内容宿主有稳定的内容与布局，而不是空壳。
        // 用约束铺满而非 autoresizing：content.view 初始 bounds 为 .zero，
        // 交给约束跟随其后的尺寸变化更可靠。
        let filler = UIView()
        filler.backgroundColor = .clear
        filler.isOpaque = false
        filler.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(filler)
        NSLayoutConstraint.activate([
            filler.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            filler.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            filler.topAnchor.constraint(equalTo: content.view.topAnchor),
            filler.bottomAnchor.constraint(equalTo: content.view.bottomAnchor)
        ])
        contentController = content

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: host,
            contentViewController: content
        )
        let pipController = AVPictureInPictureController(contentSource: source)
        pipController.delegate = self
        controller = pipController
        verboseLog("controller 已创建 · \(stateSummary) hostFrame=\(host.frame)")

        let protection = PiPCoexistenceProtection(controller: pipController)
        protection.verboseLogging = verboseLogging
        coexistence = protection
        protection.prepare()
        verboseLog("共存保护准备完成 · installed=\(protection.isSupported) \(stateSummary)")

        // 共存保护装不上：按用户选的兜底方案处理。
        // `.keepAlive` 时先保留基础设施并暂缓启动（绝不硬启动挤掉其它 App 的 PiP），
        // 其余情况报错交给协调器。
        if !protection.isSupported, coexistenceFallback != .keepAlive {
            onLog?("画中画共存保护不可用，按设置\(coexistenceFallback.title)")
            destroyInfrastructure()
            throw KeepAliveError.coexistenceUnavailable(name)
        }

        observeReadiness(for: pipController)
        return pipController
    }

    /// 共存保护是否真的装上了（装不上时按 `coexistenceFallback` 处理）。
    var isCoexistenceInstalled: Bool { coexistence?.isSupported ?? false }

    /// 系统里的画中画当前是否真的在显示。
    ///
    /// 与 `isActive`（我们是否还想保活）分开：启动/停止存在时间差，
    /// 判断「要不要再停一次」必须看 controller 的真实状态。
    var isDisplaying: Bool {
        controller?.isPictureInPictureActive == true
    }

    /// PiP 是否真的还在显示（回前台时用来判断保活是否被系统 / 用户结束）。
    var isLive: Bool {
        if controller?.isPictureInPictureActive == true { return true }
        // 正在建立 / 正在等待共存保护也算「活着」：否则 `reconcile` 的自愈会
        // 在启动过程中反复重建。
        return startTask != nil || startVerificationTask != nil
            || coexistenceRetryTask != nil || isWaitingForCoexistence
    }

    func stop() {
        verboseLog("stop 请求 · 之前 \(stateSummary)")
        lastStopUptime = ProcessInfo.processInfo.systemUptime
        stopVerificationTask?.cancel()
        stopVerificationTask = nil
        startVerificationTask?.cancel()
        startVerificationTask = nil
        startTask?.cancel()
        startTask = nil
        coexistenceRetryTask?.cancel()
        coexistenceRetryTask = nil
        isWaitingForCoexistence = false
        readyStreak = 0
        attemptCount = 0
        stopWaitCount = 0
        isStartPending = false
        isActive = false
        isStoppingSelf = true
        // 内容类型退回 4：下次启动重新走「先 4 后 6」，也让别的 App 的画中画恢复原状。
        coexistence?.restore()
        if let controller {
            controller.stopPictureInPicture()
            scheduleStopVerification(for: controller)
        }
        // 刻意**不**销毁 controller / 宿主视图：保留会话，下次 start() 直接复用。
        verboseLog("stop 已请求，保留会话 · \(stateSummary)")
    }

    /// 停止后核对一次真实状态，必要时重试。
    ///
    /// 系统在「startPictureInPicture() 已调用、但还没真正激活」时收到的
    /// stop 请求可能被忽略，随后窗口照样弹出来；任务结束时如果正好处于
    /// 这个窗口期，就会出现「下载已完成，画中画还在」。
    private func scheduleStopVerification(
        for controller: AVPictureInPictureController,
        attempts: Int = 3
    ) {
        guard attempts > 0 else { return }
        stopVerificationTask = Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, let controller,
                  self.controller === controller else { return }
            self.stopVerificationTask = nil
            // 期间可能已经重新开始保活，不能误停新的会话。
            guard !self.isActive, controller.isPictureInPictureActive else { return }
            self.verboseLog(
                "停止后仍在显示，重试 \(attempts) · \(self.stateSummary)"
            )
            self.isStoppingSelf = true
            controller.stopPictureInPicture()
            self.scheduleStopVerification(for: controller, attempts: attempts - 1)
        }
    }

    /// 彻底销毁画中画基础设施（用户把保活方式关掉时用）。
    func invalidate() {
        verboseLog("invalidate 请求 · \(stateSummary)")
        stop()
        destroyInfrastructure()
    }

    /// 启动是异步的：这里做一次「一次性」核对，确认 PiP 真的进入激活状态。
    private func scheduleStartVerification(for controller: AVPictureInPictureController, delay: Double) {
        verboseLog("安排启动后核对 · \(delay) 秒后")
        startVerificationTask?.cancel()
        startVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.controller === controller else { return }
            self.startVerificationTask = nil
            self.verboseLog("启动后核对 · active=\(controller.isPictureInPictureActive) suspended=\(controller.isPictureInPictureSuspended) possible=\(controller.isPictureInPicturePossible) \(self.stateSummary)")
            guard !controller.isPictureInPictureActive else { return }
            self.onLog?("画中画启动后未进入激活状态（可能被系统或其他 App 拒绝）")
            self.scheduleStartRetry(for: controller)
        }
    }

    /// 观察 `isPictureInPicturePossible`；就绪后立即尝试启动。
    ///
    /// 回调里再包一层 `Task`：KVO 可能在非主线程 / 构造期间同步触发，
    /// 异步派发可以避免重入。
    private func observeReadiness(for controller: AVPictureInPictureController) {
        possibleObservation?.invalidate()
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, change in
            let observedPossible = change.newValue ?? controller.isPictureInPicturePossible
            Task { @MainActor in
                guard let self, self.controller === controller else { return }
                self.verboseLog("就绪状态回调 · observedPossible=\(observedPossible) \(self.stateSummary)")
                self.attemptStartIfPossible(controller)
            }
        }
    }

    /// 就绪才启动，且要求「连续三次为 true」以避免用瞬时值启动。
    ///
    /// 为什么不能见到一次 true 就启动：刚创建 controller 时 `isPictureInPicturePossible`
    /// 可能是瞬时 true，随后系统才算出真值 false（例如其他 App 已经有画中画）。
    /// 用瞬时值 `startPictureInPicture()` 会把对方挤掉、自己却起不来 ——
    /// 表现就是「启动保活时中断了其他 App 的画中画，保活本身也没成功」。
    private func attemptStartIfPossible(_ controller: AVPictureInPictureController) {
        verboseLog("评估启动 · stopWait=\(stopWaitCount) \(stateSummary)")
        guard self.controller === controller, isActive, !isStartPending else { return }

        if controller.isPictureInPictureActive {
            // 只有「我们自己请求过停止、系统还在收尾」才需要等：
            // 其余情况说明会话本来就活着，什么都不用做。
            guard isStoppingSelf else {
                verboseLog("PiP 已激活且不是我们请求的停止，保持现状")
                return
            }
            stopWaitCount += 1
            guard stopWaitCount <= Self.maxStopWaitAttempts else {
                // 停止请求迟迟没生效：那就按「会话仍在运行」处理（对保活来说这正是想要的状态）。
                stopWaitCount = 0
                isStoppingSelf = false
                onLog?("画中画停止迟迟未完成，按现有会话继续")
                verboseLog("停止迟迟未完成，按激活会话继续 · \(stateSummary)")
                return
            }
            verboseLog("等待停止收尾 · \(stopWaitCount)/\(Self.maxStopWaitAttempts) \(stateSummary)")
            scheduleStartAttempt(for: controller, delay: Self.startRetryDelay)
            return
        }
        stopWaitCount = 0

        // 没有共存保护就绝不启动：那会把其他 App 正在播放的画中画挤掉。
        // `.keepAlive` 现在表示「暂缓启动，等保护就绪」，而不是「硬启动」。
        guard coexistence?.isSupported == true else {
            switch coexistenceFallback {
            case .keepAlive:
                beginWaitingForCoexistence(for: controller)
            case .silentAudio, .stop:
                onLog?("画中画共存保护不可用，已停止启动（避免打断其他 App 的画中画）")
                onStartFailure?()
            }
            return
        }
        if isWaitingForCoexistence {
            isWaitingForCoexistence = false
            coexistenceRetryTask?.cancel()
            coexistenceRetryTask = nil
            onLog?("画中画共存保护已就绪，继续启动")
        }

        guard controller.isPictureInPicturePossible else {
            readyStreak = 0
            attemptCount += 1
            verboseLog("尚未就绪 · attempt=\(attemptCount) \(stateSummary)")
            // 不因为「长时间未就绪」就放弃会话：就绪状态可能只是被别人占着的一段时间。
            // 一旦放弃，就只能等用户把 App 切后台再回来才会重建 —— 表现就是
            // 「取消任务后再继续，画中画再也拉不起来」。这里改为低速持续重试。
            if attemptCount % Self.startAttemptsPerNotice == 0 {
                onLog?("画中画暂未就绪，继续等待（第 \(attemptCount) 次）")
            }
            let delay = attemptCount <= Self.maxFastStartAttempts
                ? Self.startRetryDelay
                : Self.startSlowRetryDelay
            scheduleStartAttempt(for: controller, delay: delay)
            return
        }

        // 一旦就绪，就把「未就绪」的等待计数清零，避免瞬时抖动把预算耗光。
        attemptCount = 0
        readyStreak += 1
        guard readyStreak >= Self.requiredReadyStreak else {
            // 看到 true 先不启动，隔一个很短的窗口再确认。
            verboseLog("就绪抖动确认 · streak=\(readyStreak)/\(Self.requiredReadyStreak)")
            scheduleStartAttempt(for: controller, delay: Self.startSettleDelay)
            return
        }

        // 刚结束过 PiP（例如任务下载完自动停止，紧接着切了保活模式）：推迟到冷却结束再启动。
        let now = ProcessInfo.processInfo.systemUptime
        if let lastStop = lastStopUptime, now - lastStop < Self.restartCooldown {
            let remaining = Self.restartCooldown - (now - lastStop)
            verboseLog("启动冷却中 · remaining=\(String(format: "%.2f", remaining)) 秒")
            scheduleStartAttempt(for: controller, delay: remaining)
            return
        }

        onLog?("画中画已就绪，开始启动（窗口 \(pipSize.width)×\(pipSize.height) pt）")
        verboseLog("调用 startPictureInPicture() · \(stateSummary)")
        readyStreak = 0
        isStartPending = true
        controller.startPictureInPicture()
        scheduleStartVerification(for: controller, delay: Self.startVerificationDelay)
    }

    /// 共存保护不可用时暂缓启动，并低频重试安装。
    ///
    /// 这是「不打断其他 App 的画中画」的硬约束：在保护就绪之前，
    /// `startPictureInPicture()` 一次都不会被调用。
    private func beginWaitingForCoexistence(
        for controller: AVPictureInPictureController,
        attempt: Int = 0
    ) {
        guard self.controller === controller, isActive else { return }
        if attempt == 0 {
            guard !isWaitingForCoexistence, coexistenceRetryTask == nil else { return }
            isWaitingForCoexistence = true
            attemptCount = 0
            readyStreak = 0
            onLog?("共存保护暂不可用，已暂缓启动画中画（避免打断其他 App 的画中画）")
            verboseLog("等待共存保护 · \(stateSummary)")
        }
        guard attempt < Self.maxCoexistenceWaitAttempts else {
            isWaitingForCoexistence = false
            onLog?("共存保护仍不可用，本次未启动画中画")
            verboseLog("等待共存保护超时，上报启动失败 · \(stateSummary)")
            onStartFailure?()
            return
        }
        coexistenceRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.coexistenceRetryDelay))
            guard let self, !Task.isCancelled, self.isActive,
                  self.controller === controller else { return }
            self.coexistenceRetryTask = nil
            guard self.coexistence?.isSupported != true else {
                self.attemptStartIfPossible(controller)
                return
            }
            self.coexistence?.prepare()
            guard self.coexistence?.isSupported == true else {
                self.beginWaitingForCoexistence(for: controller, attempt: attempt + 1)
                return
            }
            self.attemptStartIfPossible(controller)
        }
    }

    /// 延迟后再试一次（抖动确认 / 未就绪重试共用同一个任务）。
    private func scheduleStartAttempt(for controller: AVPictureInPictureController, delay: Double) {
        verboseLog("安排启动尝试 · delay=\(String(format: "%.2f", delay)) 秒 \(stateSummary)")
        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.startTask = nil
            self.attemptStartIfPossible(controller)
        }
    }

    /// 启动失败（被系统拒绝 / 迟迟未激活）后的有界重试。
    ///
    /// 「取消任务后马上继续」是最常见的操作：上一个画中画刚结束，系统常会拒绝紧接着的
    /// 新建（`AVKitErrorDomain -1001`）。以前一次失败就彻底放弃，只能等用户把 App 切后台
    /// 再回来才重建 —— 表现就是「继续 / 重试任务时拉不起保活」。
    /// 这里改为退避重试若干次，仍失败才上报中断。
    private func scheduleStartRetry(for controller: AVPictureInPictureController) {
        guard self.controller === controller, isActive else { return }
        startRetryCount += 1
        guard startRetryCount <= Self.maxStartRetries else {
            startRetryCount = 0
            onStartFailure?()
            return
        }
        let delay = Self.restartCooldown * Double(startRetryCount)
        onLog?("画中画将在 \(delay) 秒后重试（第 \(startRetryCount)/\(Self.maxStartRetries) 次）")
        verboseLog("启动重试计数 · \(startRetryCount)/\(Self.maxStartRetries) delay=\(delay) 秒 \(stateSummary)")
        readyStreak = 0
        scheduleStartAttempt(for: controller, delay: delay)
    }

    // MARK: - 内部

    /// 销毁基础设施（只在「关掉保活方式」或宿主视图失效时用）。
    private func destroyInfrastructure() {
        verboseLog("销毁基础设施 · before \(stateSummary)")
        isActive = false
        possibleObservation?.invalidate()
        possibleObservation = nil
        stopVerificationTask?.cancel()
        stopVerificationTask = nil
        startVerificationTask?.cancel()
        startVerificationTask = nil
        startTask?.cancel()
        startTask = nil
        coexistenceRetryTask?.cancel()
        coexistenceRetryTask = nil
        isWaitingForCoexistence = false
        readyStreak = 0
        attemptCount = 0
        startRetryCount = 0
        isStartPending = false
        isStoppingSelf = false
        coexistence?.restore()
        coexistence = nil
        controller?.delegate = nil
        controller = nil
        sourceWidth?.isActive = false
        sourceHeight?.isActive = false
        sourceWidth = nil
        sourceHeight = nil
        sourceView?.removeFromSuperview()
        sourceView = nil
        contentController = nil
    }

    /// 把当前尺寸即时应用到已启动的 PiP：更新宿主视图约束与内容尺寸。
    ///
    /// 只调整几何，不重建会话 —— 重建会打断保活。窗口由系统在下次布局时跟随。
    private func applySizeToRunningPiP() {
        // 暂停期间也要跟随：会话是复用的，下次启动必须用最新尺寸。
        guard controller != nil else { return }
        let size = pipSize
        sourceWidth?.constant = size.width
        sourceHeight?.constant = size.height
        contentController?.preferredContentSize = size
        sourceView?.superview?.layoutIfNeeded()
        verboseLog("应用 PiP 尺寸 · size=\(size) hostFrame=\(sourceView?.frame ?? .zero)")
    }

    /// 找一个可用的宿主窗口。
    ///
    /// 不要求必须是 key window：App 在后台、或弹着 sheet 时 key window 可能为空，
    /// 但任意一个可见窗口都能提供合法的几何来源 —— 过度严格会让『继续/重试任务』时拉不起保活。
    private static func hostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }

        if let key = windows.first(where: { $0.isKeyWindow }) { return key }

        let foreground = scenes.first(where: { $0.activationState == .foregroundActive })
        if let window = foreground?.windows.first { return window }

        return windows.first
    }

    /// 在宿主窗口上挂一个透明、高度由设置决定的 source view，作为 PiP 的几何来源。
    private func makeHostView() throws -> UIView {
        verboseLog("查找宿主窗口 · \(Self.sceneSummary())")
        guard let window = Self.hostWindow() else {
            // 没有前台窗口只是「暂时」拿不到宿主，并非设备不支持，
            // 用单独的错误文案区分，避免误导排查方向。
            verboseLog("未找到宿主窗口 · \(Self.sceneSummary())")
            throw KeepAliveError.unavailable(name)
        }

        let host = UIView()
        host.backgroundColor = .clear
        host.isOpaque = false
        // 这个视图只是一块透明的几何来源，但会长期留在窗口里（会话复用），
        // 必须关掉触摸，否则它会挡住中间那片区域的手势。
        host.isUserInteractionEnabled = false
        host.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(host)

        let width = host.widthAnchor.constraint(equalToConstant: pipSize.width)
        let height = host.heightAnchor.constraint(equalToConstant: pipSize.height)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: window.centerYAnchor),
            width,
            height
        ])
        sourceWidth = width
        sourceHeight = height
        sourceView = host
        window.layoutIfNeeded()
        verboseLog("宿主视图已挂载 · windowBounds=\(window.bounds) hostFrame=\(host.frame) hidden=\(window.isHidden) key=\(window.isKeyWindow)")
        return host
    }
}

extension PictureInPictureKeepAlive: @preconcurrency AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        verboseLog("delegate didStart · \(stateSummary)")
        isStartPending = false
        startVerificationTask?.cancel()
        startVerificationTask = nil
        startTask?.cancel()
        startTask = nil
        readyStreak = 0
        attemptCount = 0
        startRetryCount = 0

        // 启动是异步的：等待期间任务可能已经结束 / 切换了保活方式。
        // 这时 stop() 可能早于系统真正激活而被忽略，窗口随后才弹出来；
        // 必须在这里补一次停止，否则它会一直留着。
        guard isActive else {
            stopVerificationTask?.cancel()
            stopVerificationTask = nil
            isStoppingSelf = true
            verboseLog("didStart 但已不需要保活，立即停止 · \(stateSummary)")
            controller.stopPictureInPicture()
            scheduleStopVerification(for: controller)
            return
        }

        isStoppingSelf = false
        // 启动前已经是共存类型 6；这里再确认一次，防止启动过程中被退回普通类型。
        coexistence?.confirmCoexistenceType(for: controller)
        coexistence?.schedulePostStartUpdate(for: controller)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        verboseLog("delegate didStop · isStoppingSelf=\(isStoppingSelf) \(stateSummary)")
        // 我们自己发起的停止（任务结束 / 切保活方式）：只算暂停会话，
        // 既不当成「被系统或用户结束」，也不要销毁基础设施 —— 下次 start() 直接复用。
        if isStoppingSelf {
            isStoppingSelf = false
            return
        }
        // 用户主动关闭 / 被系统结束 → 交给协调器处理。
        Task { @MainActor in self.onInterruption?() }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            // 把系统给的原因原样带出来 —— 之前这里被吞掉了，日志里只剩「未进入激活状态」。
            self.isStartPending = false
            self.startVerificationTask?.cancel()
            self.startVerificationTask = nil
            let nsError = error as NSError
            self.onLog?("画中画启动被系统拒绝：\(nsError.domain) \(nsError.code) — \(nsError.localizedDescription)")
            self.verboseLog("delegate start failed · \(nsError.domain) \(nsError.code) userInfo=\(nsError.userInfo) \(self.stateSummary)")
            self.scheduleStartRetry(for: controller)
        }
    }
}
