import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser

// MARK: - WKWebView 容器（含下拉刷新）

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    /// 滚动偏移回调：供外层收缩地址栏。
    var onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(webView: webView, onScroll: onScroll)
    }

    func makeUIView(context: Context) -> WKWebView {
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

        context.coordinator.startObservingOffset()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onScroll = onScroll
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
