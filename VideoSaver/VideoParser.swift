import Foundation
import WebKit

/// 浏览器宿主 + 解析调度。具体站点的规则由 `VideoSiteParser` 实现。
@MainActor
final class VideoParser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var pageMatchesRule = false
    @Published private(set) var pageReady = false

    private let webView: WKWebView
    private let appState: AppState
    private let registry: VideoSiteParserRegistry

    init(appState: AppState, registry: VideoSiteParserRegistry = .default) {
        self.appState = appState
        self.registry = registry
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        // 边缘左右滑动 = 后退 / 前进（替代原先的三个按钮）
        webView.allowsBackForwardNavigationGestures = true
        // 拖动页面即收起键盘
        webView.scrollView.keyboardDismissMode = .onDrag
    }

    var browserWebView: WKWebView { webView }
    var canParseCurrentPage: Bool { pageReady && pageMatchesRule && !isLoading }

    /// 当前页面命中的站点名，可用于 UI 提示。
    var currentSiteName: String? { registry.parser(for: webView.url)?.displayName }

    func load(_ url: URL) {
        isLoading = true
        pageReady = false
        pageMatchesRule = registry.canHandle(url)
        webView.load(URLRequest(url: url))
    }

    func parseCurrentPage() async throws -> ParsedVideo {
        guard canParseCurrentPage else {
            if !pageMatchesRule { throw ParserError.unsupportedURL }
            throw ParserError.pageLoadFailed("页面尚未加载完成。")
        }

        guard let pageURL = webView.url else { throw ParserError.invalidURL }
        guard let siteParser = registry.parser(for: pageURL) else {
            throw ParserError.unsupportedURL
        }

        let page = WKWebPageContext(webView: webView)
        let variants = try await siteParser.parse(page: page)

        guard !variants.isEmpty else { throw ParserError.noVideoVariants }

        let title = await page.documentTitle() ?? pageURL.host ?? "Video"
        appState.addHistory(title: title, url: pageURL)
        return ParsedVideo(title: title, pageURL: pageURL, variants: variants)
    }

    /// 供下载请求复用：当前页面的 Cookie 头。
    func cookieHeaderForCurrentPage() async -> String? {
        await WKWebPageContext(webView: webView).cookieHeader(matching: webView.url)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        pageReady = false
        pageMatchesRule = registry.canHandle(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        pageReady = true
        pageMatchesRule = registry.canHandle(webView.url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        pageReady = false
        pageMatchesRule = registry.canHandle(webView.url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        pageReady = false
        pageMatchesRule = registry.canHandle(webView.url)
    }
}