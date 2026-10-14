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

    /// 是否以最小化方式显示 PiP：开启时高度压到 0.1pt（视觉隐藏），
    /// 关闭时显示为普通可见小窗。由设置页切换。
    var isMinimized = true

    /// PiP 悬浮窗尺寸。最小化时高 0.1pt（不可见），否则 12:9 的普通小窗。
    private var pipSize: CGSize {
        isMinimized ? CGSize(width: 300, height: 0.1) : CGSize(width: 300, height: 225)
    }

    /// 启动后的「一次性」核对任务，确认 PiP 真的进入激活状态。
    private var startVerificationTask: Task<Void, Never>?
    /// 观察 `isPictureInPicturePossible`，就绪后再启动。
    private var possibleObservation: NSKeyValueObservation?

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
        //
        // 启动时机交给 KVO：`isPictureInPicturePossible` 是**异步**就绪的，
        // 创建 controller 后立刻 `startPictureInPicture()` 往往会被系统静默忽略，
        // 表现为「一直没进入激活状态」。等它就绪后再启动即可。
        observeReadiness(for: pipController)
        // 兜底看门狗：若一段时间内始终没能激活（可能不可用），上报一次中断。
        scheduleStartVerification(for: pipController, delay: 5)
    }

    /// 共存保护是否真的装上了（装不上时按 `coexistenceFallback` 处理）。
    var isCoexistenceInstalled: Bool { coexistence?.isSupported ?? false }

    /// PiP 是否真的还在显示（回前台时用来判断保活是否被系统 / 用户结束）。
    var isLive: Bool { controller?.isPictureInPictureActive ?? false }

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
            guard !controller.isPictureInPictureActive else { return }
            self.onLog?("画中画启动后未进入激活状态（可能被系统或其他 App 拒绝）")
            self.onInterruption?()
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

    /// 就绪即启动；重复触发由 `isPictureInPictureActive` 兜住。
    private func attemptStartIfPossible(_ controller: AVPictureInPictureController) {
        guard !controller.isPictureInPictureActive else { return }
        guard controller.isPictureInPicturePossible else {
            // 用于排查「一直没激活」：说明系统始终没判定为可启动。
            onLog?("画中画尚未就绪（isPictureInPicturePossible = false）")
            return
        }
        onLog?("画中画已就绪，开始启动")
        controller.startPictureInPicture()
        scheduleStartVerification(for: controller, delay: 3)
    }

    // MARK: - 内部

    private func cleanup() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        startVerificationTask?.cancel()
        startVerificationTask = nil
        sourceWidth?.isActive = false
        sourceHeight?.isActive = false
        sourceWidth = nil
        sourceHeight = nil
        sourceView?.removeFromSuperview()
        sourceView = nil
        contentController = nil
        controller = nil
    }

    /// 在 key window 上挂一个透明、高度 0.1pt 的 source view，作为 PiP 的几何来源。
    private func makeHostView() throws -> UIView {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
        else {
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
        Task { @MainActor in self.onInterruption?() }
    }
}
