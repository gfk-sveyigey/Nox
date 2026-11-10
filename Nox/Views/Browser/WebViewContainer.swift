import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser

// MARK: - WKWebView 容器（含下拉刷新）

struct WebViewContainer: UIViewControllerRepresentable {
    let webView: WKWebView
    var backgroundColor: UIColor
    var addressBarInset: CGFloat
    /// Normalized distance from the top and actual scroll movement, excluding inset changes.
    var onScroll: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(webView: webView, onScroll: onScroll)
    }

    func makeUIViewController(context: Context) -> BrowserContentController {
        // 下拉刷新（替代原来的「刷新」按钮）
        if webView.scrollView.refreshControl == nil {
            let control = UIRefreshControl()
            control.addTarget(
                context.coordinator,
                action: #selector(Coordinator.refresh),
                for: .valueChanged
            )
            webView.scrollView.refreshControl = control
        }

        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.scrollsToTop = true
        webView.scrollView.clipsToBounds = false
        webView.clipsToBounds = false
        let controller = BrowserContentController(webView: webView)
        controller.pageBackgroundColor = backgroundColor
        controller.addressBarInset = addressBarInset
        context.coordinator.controller = controller
        context.coordinator.startObservingOffset()
        return controller
    }

    func updateUIViewController(_ controller: BrowserContentController, context: Context) {
        context.coordinator.onScroll = onScroll
        controller.pageBackgroundColor = backgroundColor
        controller.setAddressBarInset(addressBarInset)
        controller.connectContentScrollView()
    }

    final class Coordinator {
        private weak var webView: WKWebView?
        private var observation: NSKeyValueObservation?
        private var offsetObservation: NSKeyValueObservation?
        weak var controller: BrowserContentController?
        private var previousOffset: CGFloat?
        var onScroll: (CGFloat, CGFloat) -> Void

        init(webView: WKWebView, onScroll: @escaping (CGFloat, CGFloat) -> Void) {
            self.webView = webView
            self.onScroll = onScroll

            // 加载结束后收起刷新指示器，否则会一直转
            observation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                if webView.isLoading {
                    return
                }
                webView.scrollView.refreshControl?.endRefreshing()
            }
        }

        func startObservingOffset() {
            guard offsetObservation == nil, let webView else { return }

            // Ignore layout-driven offsets; defer SwiftUI state changes outside UIKit updates.
            offsetObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                guard let self else { return }
                let offset = scrollView.contentOffset.y
                let delta = offset - (self.previousOffset ?? offset)
                self.previousOffset = offset
                guard self.controller?.isUpdatingInset != true,
                      !webView.isLoading,
                      scrollView.isDragging || scrollView.isDecelerating else { return }
                let distance = offset + scrollView.adjustedContentInset.top
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.webView?.isLoading == false else { return }
                    self.onScroll(distance, delta)
                }
            }
        }

        @objc func refresh() {
            webView?.reload()
        }
    }
}

/// Register WebKit's nested scroll view with the native tab containers.
final class BrowserContentController: UIViewController {
    private let webView: WKWebView
    var pageBackgroundColor: UIColor = .systemBackground {
        didSet { viewIfLoaded?.backgroundColor = pageBackgroundColor }
    }
    var addressBarInset: CGFloat = 0
    private(set) var isUpdatingInset = false
    func setAddressBarInset(_ inset: CGFloat) {
        guard abs(addressBarInset - inset) > 0.5 else { return }
        addressBarInset = inset
        guard isViewLoaded else { return }
        // Keep the page anchored while the independently overlaid address bar
        // animates. Animating WebKit's frame triggers repeated viewport reflow.
        UIView.performWithoutAnimation { self.updateTopContentInset() }
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = UIView()
        view.backgroundColor = pageBackgroundColor
        view.clipsToBounds = true
        view.addSubview(webView)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTopContentInset()
    }
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateTopContentInset()
    }

    // At rest the first page pixel is below the visible address bar. Scrolling can
    // still carry page content behind the safe-area material.
    private func updateTopContentInset() {
        guard isViewLoaded else { return }
        let scroll = webView.scrollView
        let top = view.safeAreaInsets.top + addressBarInset
        let frame = CGRect(x: 0, y: top, width: view.bounds.width, height: max(0, view.bounds.height - top))
        guard webView.frame != frame || scroll.contentInset.top != 0 else { return }
        isUpdatingInset = true
        defer { isUpdatingInset = false }
        // A real viewport origin, not a scroll inset: window.scrollTo(0, 0),
        // input focus and WebKit navigation all agree on the same page top.
        let oldFrame = webView.frame
        let oldOffset = scroll.contentOffset
        let preserveAnchor = oldFrame.width == frame.width
            && oldFrame.height > 0 && oldOffset.y > -scroll.adjustedContentInset.top + 1
        webView.frame = frame
        if preserveAnchor {
            // screenY = viewportOrigin + documentY - contentOffset.
            // Compensate the origin change instead of moving the page on screen.
            let targetY = oldOffset.y + frame.minY - oldFrame.minY
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: oldOffset.x, y: min(maximum, max(minimum, targetY))), animated: false)
        }
        if scroll.contentInset.top != 0 {
            var inset = scroll.contentInset
            inset.top = 0
            scroll.contentInset = inset
        }
        var indicators = scroll.verticalScrollIndicatorInsets
        indicators.top = 0
        scroll.verticalScrollIndicatorInsets = indicators
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        connectContentScrollView()
    }
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.connectContentScrollView() }
    }
    func connectContentScrollView() {
        guard #available(iOS 26.0, *) else { return }
        var controller: UIViewController? = self
        while let current = controller, !(current is UITabBarController) {
            current.setContentScrollView(webView.scrollView)
            controller = current.parent
        }
    }
}
