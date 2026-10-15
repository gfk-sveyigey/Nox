import AVFoundation
import AVKit
import Foundation
import UIKit

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
    /// 用于在前台做有限次重试。
    var onStartFailure: (() -> Void)?

    /// 诊断信息出口（内部适配是否可用等），由协调器转接到日志。
    var onLog: ((String) -> Void)?

    /// 共存保护装不上时的处理方式，由协调器按用户在设置里选的值同步过来。
    var coexistenceFallback: PiPCoexistenceFallback = .keepAlive

    private var controller: AVPictureInPictureController?
    private var contentController: AVPictureInPictureVideoCallViewController?
    private weak var sourceView: UIView?
    private var sourceWidth: NSLayoutConstraint?
    private var sourceHeight: NSLayoutConstraint?
    private var coexistence: PiPCoexistenceProtection?

    /// PiP 悬浮窗高度（pt），由设置页滑块调节。0 表示最小化：0.1pt，视觉隐藏。
    ///
    /// 改动时**不重建** PiP 会话：刚停掉就立刻重启常被系统拒绝，
    /// 会导致保活直接失效；这里只更新宿主视图尺寸并即时生效。
    var windowHeight: Double = AppState.defaultPiPWindowHeight {
        didSet {
            guard windowHeight != oldValue else { return }
            applySizeToRunningPiP()
        }
    }

    /// PiP 悬浮窗尺寸：宽度固定 300pt，高度由滑块决定；0 时压到 0.1pt（不可见）。
    private var pipSize: CGSize {
        let height = windowHeight < 1 ? AppState.minimizedPiPWindowHeight : windowHeight
        return CGSize(width: 300, height: height)
    }

    /// 启动后的「一次性」核对任务，确认 PiP 真的进入激活状态。
    private var startVerificationTask: Task<Void, Never>?
    /// 观察 `isPictureInPicturePossible`，就绪后再启动。
    private var possibleObservation: NSKeyValueObservation?

    /// 启动重试 / 抖动确认的统一任务。
    private var startTask: Task<Void, Never>?
    /// 连续观察到 `isPictureInPicturePossible == true` 的次数（抖动确认用）。
    private var readyStreak = 0
    /// 已尝试启动的次数（有界重试，避免无限轮询抢占 System）。
    private var attemptCount = 0

    /// 抖动确认窗口：刚创建 controller 时 `isPictureInPicturePossible` 常是瞬时 true，
    /// 之后系统才算出真值。要求它连续两次为 true 才真正启动。
    private static let startSettleDelay: Double = 0.6
    /// 未就绪时的重试间隔。
    private static let startRetryDelay: Double = 0.8
    /// 启动尝试次数上限（约 12 秒）。
    private static let maxStartAttempts = 15
    /// 启动后核对是否进入激活状态的延迟。
    private static let startVerificationDelay: Double = 3

    func start() throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw KeepAliveError.unsupported(name)
        }
        guard controller == nil else { return }

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

        let protection = PiPCoexistenceProtection(controller: pipController)
        coexistence = protection
        protection.prepare()

        // 共存保护装不上：按用户选的兜底方案处理。
        // `.keepAlive` 时继续启动（可能挤掉其它 App 的 PiP），其余情况报错交给协调器。
        if !protection.isSupported, coexistenceFallback != .keepAlive {
            onLog?("画中画共存保护不可用，按设置\(coexistenceFallback.title)")
            coexistence = nil
            cleanup()
            throw KeepAliveError.coexistenceUnavailable(name)
        }

        isActive = true
        // 直接以 0.1pt 启动（不是先开大再缩小），避免闪一下可见窗口。
        readyStreak = 0
        attemptCount = 0
        observeReadiness(for: pipController)
        // 立刻尝试一次；未就绪则交给有界重试（见 attemptStartIfPossible）。
        attemptStartIfPossible(pipController)
    }

    /// 共存保护是否真的装上了（装不上时按 `coexistenceFallback` 处理）。
    var isCoexistenceInstalled: Bool { coexistence?.isSupported ?? false }

    /// PiP 是否真的还在显示（回前台时用来判断保活是否被系统 / 用户结束）。
    var isLive: Bool {
        if controller?.isPictureInPictureActive == true { return true }
        // 正在建立中也算「活着」：否则 `reconcile` 的自愈会在启动过程中反复重建。
        return startTask != nil || startVerificationTask != nil
    }

    func stop() {
        startVerificationTask?.cancel()
        startVerificationTask = nil
        coexistence?.restore()
        coexistence = nil
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        cleanup()
        isActive = false
    }

    /// 启动是异步的：这里做一次「一次性」核对，确认 PiP 真的进入激活状态。
    ///
    /// 若长时间没进激活（被系统或其它 App 拒绝、设备处于不支持场景），
    /// 上报一次中断，由协调器记录并从「未保活」开始重建。这里不是轮询，也不会重复提交。
    private func scheduleStartVerification(for controller: AVPictureInPictureController, delay: Double) {
        startVerificationTask?.cancel()
        startVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.controller === controller else { return }
            self.startVerificationTask = nil
            guard !controller.isPictureInPictureActive else { return }
            self.onLog?("画中画启动后未进入激活状态（可能被系统或其他 App 拒绝）")
            self.onStartFailure?()
        }
    }

    /// 观察 `isPictureInPicturePossible`；就绪后立即尝试启动。
    ///
    /// 回调里再包一层 `Task`：KVO 可能在非主线程 / 构造期间同步触发，
    /// 异步派发可以避免重入。
    private func observeReadiness(for controller: AVPictureInPictureController) {
        possibleObservation?.invalidate()
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            Task { @MainActor in
                guard let self, self.controller === controller else { return }
                self.attemptStartIfPossible(controller)
            }
        }
    }

    /// 就绪才启动，且要求「连续两次为 true」以避免用瞬时值启动。
    ///
    /// 为什么不能见到一次 true 就启动：刚创建 controller 时 `isPictureInPicturePossible`
    /// 可能是瞬时 true，随后系统才算出真值 false（例如其他 App 已经有画中画）。
    /// 用瞬时值 `startPictureInPicture()` 会把对方挤掉、自己却起不来 ——
    /// 表现就是「启动保活时中断了其他 App 的画中画，保活本身也没成功」。
    private func attemptStartIfPossible(_ controller: AVPictureInPictureController) {
        guard self.controller === controller, isActive, !controller.isPictureInPictureActive else { return }

        guard controller.isPictureInPicturePossible else {
            readyStreak = 0
            attemptCount += 1
            guard attemptCount <= Self.maxStartAttempts else {
                onLog?("画中画始终无法启动（长时间未就绪，可能被其他 App 的画中画占用）")
                onStartFailure?()
                return
            }
            scheduleStartAttempt(for: controller, delay: Self.startRetryDelay)
            return
        }

        readyStreak += 1
        guard readyStreak >= 2 else {
            // 第一次看到 true 先不启动，隔一个很短的窗口再确认一次。
            scheduleStartAttempt(for: controller, delay: Self.startSettleDelay)
            return
        }

        onLog?("画中画已就绪，开始启动")
        readyStreak = 0
        controller.startPictureInPicture()
        scheduleStartVerification(for: controller, delay: Self.startVerificationDelay)
    }

    /// 延迟后再试一次（抖动确认 / 未就绪重试共用同一个任务）。
    private func scheduleStartAttempt(for controller: AVPictureInPictureController, delay: Double) {
        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.startTask = nil
            self.attemptStartIfPossible(controller)
        }
    }

    // MARK: - 内部

    private func cleanup() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        startVerificationTask?.cancel()
        startVerificationTask = nil
        startTask?.cancel()
        startTask = nil
        readyStreak = 0
        attemptCount = 0
        sourceWidth?.isActive = false
        sourceHeight?.isActive = false
        sourceWidth = nil
        sourceHeight = nil
        sourceView?.removeFromSuperview()
        sourceView = nil
        contentController = nil
        controller = nil
    }

    /// 把当前尺寸即时应用到已启动的 PiP：更新宿主视图约束与内容尺寸。
    ///
    /// 只调整几何，不重建会话 —— 重建会打断保活。窗口由系统在下次布局时跟随。
    private func applySizeToRunningPiP() {
        guard isActive else { return }
        let size = pipSize
        sourceWidth?.constant = size.width
        sourceHeight?.constant = size.height
        contentController?.preferredContentSize = size
        sourceView?.superview?.layoutIfNeeded()
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
        guard let window = Self.hostWindow() else {
            // 没有前台窗口只是「暂时」拿不到宿主，并非设备不支持，
            // 用单独的错误文案区分，避免误导排查方向。
            throw KeepAliveError.unavailable(name)
        }

        let host = UIView()
        host.backgroundColor = .clear
        host.isOpaque = false
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
        return host
    }
}

extension PictureInPictureKeepAlive: @preconcurrency AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        startVerificationTask?.cancel()
        startVerificationTask = nil
        startTask?.cancel()
        startTask = nil
        readyStreak = 0
        // 启动成功后再延迟提交共存类型，避免与其他 PiP 争抢。
        coexistence?.schedulePostStartUpdate(for: controller)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        // 用户主动关闭 / 被系统结束 → 交给协调器按降级链处理。
        Task { @MainActor in self.onInterruption?() }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in self.onStartFailure?() }
    }
}
