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
        let filler = UIView(frame: content.view.bounds)
        filler.backgroundColor = .clear
        filler.isOpaque = false
        filler.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.view.addSubview(filler)
        contentController = content

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: host,
            contentViewController: content
        )
        guard let pipController = AVPictureInPictureController(contentSource: source) else {
            cleanup()
            throw KeepAliveError.unsupported(name)
        }
        pipController.delegate = self
        controller = pipController

        let protection = PiPCoexistenceProtection(controller: pipController)
        protection.onLog = { [weak self] in self?.onLog?($0) }
        coexistence = protection
        protection.prepare()

        // 直接以 0.1pt 启动（不是先开大再缩小），避免闪一下可见窗口。
        pipController.startPictureInPicture()
        isActive = true
    }

    /// PiP 是否真的还在显示（回前台时用来判断保活是否被系统 / 用户结束）。
    var isLive: Bool { controller?.isPictureInPictureActive ?? false }

    func stop() {
        coexistence?.restore()
        coexistence = nil
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        cleanup()
        isActive = false
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
            throw KeepAliveError.unsupported(name)
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
