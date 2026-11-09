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
    /// 滚动偏移回调：供外层收缩地址栏。
    var onScroll: (CGFloat) -> Void

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
        context.coordinator.startObservingOffset()
        return BrowserContentController(webView: webView)
    }

    func updateUIViewController(_ controller: BrowserContentController, context: Context) {
        context.coordinator.onScroll = onScroll
        controller.connectContentScrollView()
    }

    final class Coordinator {
        private weak var webView: WKWebView?
        private var observation: NSKeyValueObservation?
        private var offsetObservation: NSKeyValueObservation?
        var onScroll: (CGFloat) -> Void

        init(webView: WKWebView, onScroll: @escaping (CGFloat) -> Void) {
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

            // contentOffset 的 KVO 回调在主线程投递，直接转给闭包即可（省去每帧派发的开销）
            offsetObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                self?.onScroll(scrollView.contentOffset.y)
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
    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = webView }
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
