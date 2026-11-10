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
        let controller = BrowserContentController(webView: webView)
        controller.addressBarInset = addressBarInset
        context.coordinator.controller = controller
        context.coordinator.startObservingOffset()
        return controller
    }

    func updateUIViewController(_ controller: BrowserContentController, context: Context) {
        context.coordinator.onScroll = onScroll
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
            observation = webView.observe(\.isLoading, options: [.new]) { webView, _ in
                guard !webView.isLoading else { return }
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
                guard self.controller?.isUpdatingInset != true else { return }
                let distance = offset + scrollView.adjustedContentInset.top
                DispatchQueue.main.async { [weak self] in self?.onScroll(distance, delta) }
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
    var addressBarInset: CGFloat = 0
    private(set) var isUpdatingInset = false

    func setAddressBarInset(_ inset: CGFloat) {
        guard abs(addressBarInset - inset) > 0.5 else { return }
        addressBarInset = inset
        guard isViewLoaded else { return }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.updateTopContentInset()
        }
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = webView }
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
        let previous = scroll.contentInset.top
        guard abs(top - previous) > 0.5 else { return }
        isUpdatingInset = true
        defer { isUpdatingInset = false }
        let wasAtTop = abs(scroll.contentOffset.y + previous) < 1
        var inset = scroll.contentInset
        inset.top = top
        scroll.contentInset = inset
        var indicators = scroll.verticalScrollIndicatorInsets
        indicators.top = top
        scroll.verticalScrollIndicatorInsets = indicators
        if wasAtTop {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -top), animated: false)
        }
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
