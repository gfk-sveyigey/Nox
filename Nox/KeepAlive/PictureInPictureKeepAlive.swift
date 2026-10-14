import AVFoundation
import AVKit
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

    private var controller: AVPictureInPictureController?
    private var contentController: AVPictureInPictureVideoCallViewController?
    private weak var sourceView: UIView?
    private var sourceWidth: NSLayoutConstraint?
    private var sourceHeight: NSLayoutConstraint?
    private var coexistence: PiPCoexistenceProtection?

    /// PiP 悬浮窗尺寸：宽 300pt、高 0.1pt，即视觉隐藏。
    private let pipSize = CGSize(width: 300, height: 0.1)

    /// 启动后的「一次性」核对任务，确认 PiP 真的进入激活状态。
    private var startVerificationTask: Task<Void, Never>?

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
        protection.onLog = { [weak self] in self?.onLog?($0) }
        coexistence = protection
        protection.prepare()

        // 直接以 0.1pt 启动（不是先开大再缩小），避免闪一下可见窗口。
        pipController.startPictureInPicture()
        isActive = true
        scheduleStartVerification(for: pipController)
    }

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
    /// 上报一次中断，交给协调器按降级链处理。这里不是轮询，也不会重复提交。
    private func scheduleStartVerification(for controller: AVPictureInPictureController) {
        startVerificationTask?.cancel()
        startVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.controller === controller else { return }
            guard !controller.isPictureInPictureActive else { return }
            self.onLog?("画中画启动后未进入激活状态（可能被系统或其他 App 拒绝）")
            self.onInterruption?()
        }
    }

    // MARK: - 内部

    private func cleanup() {
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
