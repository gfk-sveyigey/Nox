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

        // 嗅探脚本：跨域 iframe 也会注入，各自 postMessage 上来
        if let script = SnifferScript.userScript() {
            configuration.userContentController.addUserScript(script)
        }
        // 桥接单例，WKUserContentController 会强持有它
        configuration.userContentController.add(
            SnifferBridge.shared,
            name: SnifferBridge.handlerName
        )

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        // 边缘左右滑动 = 后退 / 前进
        webView.allowsBackForwardNavigationGestures = true
        // 拖动页面即收起键盘
        webView.scrollView.keyboardDismissMode = .onDrag
    }

    var browserWebView: WKWebView { webView }
    var canParseCurrentPage: Bool { pageReady && pageMatchesRule && !isLoading }

    /// 当前页面命中的站点名（仅当该站点开关为开启时）
    var currentSiteName: String? { activeParser(for: webView.url)?.displayName }

    func load(_ url: URL) {
        SnifferBridge.shared.reset()
        isLoading = true
        pageReady = false
        pageMatchesRule = activeParser(for: url) != nil
        webView.load(URLRequest(url: url))
    }

    func parseCurrentPage() async throws -> ParsedVideo {
        guard canParseCurrentPage else {
            if !pageMatchesRule { throw ParserError.unsupportedURL }
            throw ParserError.pageLoadFailed(L("页面尚未加载完成。"))
        }

        guard let pageURL = webView.url else { throw ParserError.invalidURL }
        guard let siteParser = activeParser(for: pageURL) else {
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

    /// 让页面里的嗅探脚本立刻重扫一遍（对应原脚本的「重新扫描」按钮）。
    /// 返回本次新上报的条数。
    @discardableResult
    func rescanPage(deep: Bool = true) async -> Int {
        let script = "window.__MS_SNIFF__ ? window.__MS_SNIFF__(\(deep)) : 0"
        let value = try? await webView.evaluateJavaScript(script)
        return (value as? Int) ?? 0
    }

    // MARK: - 站点开关

    /// 匹配站点规则 **且** 该站点在设置页处于开启状态
    private func activeParser(for url: URL?) -> VideoSiteParser? {
        guard let url else { return nil }
        return registry.parsers.first {
            appState.isSiteEnabled($0.identifier) && $0.canHandle(url)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // 换页清空上一页的嗅探结果
        SnifferBridge.shared.reset()
        isLoading = true
        pageReady = false
        pageMatchesRule = activeParser(for: webView.url) != nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        pageReady = true
        pageMatchesRule = activeParser(for: webView.url) != nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        pageReady = false
        pageMatchesRule = activeParser(for: webView.url) != nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        pageReady = false
        pageMatchesRule = activeParser(for: webView.url) != nil
    }
}