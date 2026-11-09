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
    var allowsBarHiding: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(webView: webView)
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
        controller.allowsBarHiding = allowsBarHiding
        return controller
    }

    func updateUIViewController(_ controller: BrowserContentController, context: Context) {
        controller.allowsBarHiding = allowsBarHiding
        controller.connectContentScrollView()
    }

    final class Coordinator {
        private weak var webView: WKWebView?
        private var observation: NSKeyValueObservation?

        init(webView: WKWebView) {
            self.webView = webView

            // 加载结束后收起刷新指示器，否则会一直转
            observation = webView.observe(\.isLoading, options: [.new]) { webView, _ in
                guard !webView.isLoading else { return }
                webView.scrollView.refreshControl?.endRefreshing()
            }
        }

        @objc func refresh() {
            webView?.reload()
        }
    }
}

/// Register WebKit's nested scroll view with the native tab containers.
final class BrowserContentController: UIViewController {
    var allowsBarHiding = false
    private weak var configuredNavigation: UINavigationController?
    private var previousHidesBarsOnSwipe = false
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
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restoreNavigationBehavior()
    }
    private func restoreNavigationBehavior() {
        configuredNavigation?.hidesBarsOnSwipe = previousHidesBarsOnSwipe
        configuredNavigation?.setNavigationBarHidden(false, animated: false)
        configuredNavigation = nil
    }
    func connectContentScrollView() {
        guard isViewLoaded, view.window != nil else { return }
        if let navigation = navigationController {
            if configuredNavigation !== navigation {
                restoreNavigationBehavior()
                previousHidesBarsOnSwipe = navigation.hidesBarsOnSwipe
                configuredNavigation = navigation
            }
            navigation.hidesBarsOnSwipe = allowsBarHiding
            if !allowsBarHiding { navigation.setNavigationBarHidden(false, animated: true) }
        }
        var controller: UIViewController? = self
        while let current = controller, !(current is UITabBarController) {
            current.setContentScrollView(webView.scrollView)
            controller = current.parent
        }
    }
}
