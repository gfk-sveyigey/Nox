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
    var topRequest: Int
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
        webView.scrollView.scrollsToTop = false
        webView.scrollView.clipsToBounds = false
        let controller = BrowserContentController(webView: webView)
        controller.addressBarInset = addressBarInset
        controller.lastTopRequest = topRequest
        context.coordinator.controller = controller
        context.coordinator.startObservingOffset()
        return controller
    }

    func updateUIViewController(_ controller: BrowserContentController, context: Context) {
        context.coordinator.onScroll = onScroll
        controller.setAddressBarInset(addressBarInset)
        controller.scrollToTopIfNeeded(request: topRequest)
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
                    self?.controller?.cancelTopAlignment()
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
                      self.controller?.isReturningToTop != true else { return }
                let distance = offset + scrollView.adjustedContentInset.top
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.controller?.isReturningToTop != true else { return }
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
    var addressBarInset: CGFloat = 0
    private(set) var isUpdatingInset = false
    private(set) var isReturningToTop = false
    var lastTopRequest = 0
    private var topAnimation: UIViewPropertyAnimator?
    private var keepTopAligned = false

    @objc private func userStartedScrolling(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .began else { return }
        cancelTopAlignment()
    }

    func cancelTopAlignment() {
        keepTopAligned = false
        topAnimation?.stopAnimation(true)
        topAnimation = nil
        isReturningToTop = false
    }

    private func alignToFinalTop() {
        guard keepTopAligned, !isReturningToTop else { return }
        isUpdatingInset = true
        let scroll = webView.scrollView
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
        isUpdatingInset = false
    }

    func scrollToTopIfNeeded(request: Int) {
        guard request != lastTopRequest else { return }
        lastTopRequest = request
        topAnimation?.stopAnimation(true)
        isReturningToTop = true
        keepTopAligned = true
        view.setNeedsLayout()
        view.layoutIfNeeded()
        updateTopContentInset()
        let animator = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3, curve: .easeInOut) {
            let scroll = self.webView.scrollView
            scroll.contentOffset = CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top)
        }
        animator.addCompletion { [weak self] _ in
            guard let self, self.lastTopRequest == request else { return }
            self.view.layoutIfNeeded()
            self.updateTopContentInset()
            let scroll = self.webView.scrollView
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
            self.isReturningToTop = false
            self.topAnimation = nil
        }
        topAnimation = animator
        animator.startAnimation()
    }

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
    override func loadView() {
        view = UIView()
        view.clipsToBounds = true
        view.addSubview(webView)
        webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(userStartedScrolling(_:)))
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTopContentInset()
        alignToFinalTop()
    }
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateTopContentInset()
        alignToFinalTop()
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
        webView.frame = frame
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
        // Do not register the web scroll view on ancestor navigation controllers:
        // UIKit otherwise installs its own single-tap tab-reselection scroll.
        setContentScrollView(webView.scrollView)
    }
}
