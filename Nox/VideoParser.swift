import Foundation
import UIKit
import WebKit

/// 浏览器宿主 + 解析调度。具体站点的规则由 `VideoSiteParser` 实现。
@MainActor
final class VideoParser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var pageMatchesRule = false
    @Published private(set) var pageReady = false
    /// WebView 当前地址。地址栏用它同步「页面内跳转 / 重定向」后的新地址。
    @Published private(set) var currentURL: URL?
    /// 最近一次导航失败的原因。
    ///
    /// 加载失败时 `WKWebView` 会继续显示上一个页面，用户完全看不出「新地址没打开」，
    /// 视图层会用它在页面区域**直接盖一层错误提示**（不再是弹窗）。
    @Published private(set) var loadErrorMessage: String?

    /// 最近一次加载是不是「用户主动换页」（地址栏输入 / 历史跳转）。
    ///
    /// 只有这种情况才在换页期间盖一层加载占位，避免「输入了新地址却还显示旧页面」；
    /// 页面内点链接保持浏览器习惯（旧页面留到新页面提交），但失败提示两种都会给。
    @Published private(set) var isUserInitiatedLoad = false

    /// 最近一次由用户发起的地址，供失败后的「重试」使用。
    private(set) var lastLoadURL: URL?

    private let webView: WKWebView
    /// 接收页面里 SPA 换页上报的地址（见 pageURLUserScript）。
    private let pageURLBridge: PageURLBridge
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

        // 单页应用（典型是 YouTube）点链接走 history.pushState，**不触发任何导航回调**，
        // 地址栏会一直停在旧地址上。注入脚本在 pushState / replaceState / popstate /
        // hashchange（外加定时兜底）时把新地址 postMessage 上来。
        configuration.userContentController.addUserScript(Self.pageURLUserScript())
        let pageURLBridge = PageURLBridge()
        configuration.userContentController.add(pageURLBridge, name: PageURLBridge.handlerName)

        self.pageURLBridge = pageURLBridge
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        pageURLBridge.onURLChange = { [weak self] url in
            self?.currentURL = url
        }

        // 用完整的移动版 Safari UA。
        // WKWebView 的默认 UA 缺少 `Version/... Safari/...` 段，会被部分站点
        // （典型是 YouTube）判定成机器人，要求「请登录，以便我们确认你不是聊天机器人」。
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = self
        // 边缘左右滑动 = 后退 / 前进
        webView.allowsBackForwardNavigationGestures = true
        // 拖动页面即收起键盘
        webView.scrollView.keyboardDismissMode = .onDrag

        // 深色模式：让 WebView 自身、以及页面内容之外的底色跟随系统，
        // 而不是默认的死白。用系统动态色，切换外观时会自动重算。
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.underPageBackgroundColor = .systemBackground
    }

    var browserWebView: WKWebView { webView }
    var canParseCurrentPage: Bool { pageReady && pageMatchesRule && !isLoading }

    /// 当前页面命中的站点名（仅当该站点开关为开启时）
    var currentSiteName: String? { activeParser(for: webView.url)?.displayName }

    /// 当前页面实际生效的解析器标识。
    ///
    /// 视图层用它区分「这条页面是被具名站点接管的，还是靠通用嗅探兜底」——
    /// 具名站点命中时，嗅探入口没有存在意义（解析结果更准，且会重复）。
    var currentParserIdentifier: String? { activeParser(for: webView.url)?.identifier }

    /// 当前页面地址。
    ///
    /// 从嗅探面板加入下载时，历史记的是**页面**地址而不是媒体地址：
    /// 这样历史页的「跳转网页」能回到原页面，同一页面上的多条资源也不会各占一条记录。
    var currentPageURL: URL? { webView.url }

    /// 当前页面标题。WKWebView 加载完成后会自动维护，取用无需再执行 JS。
    var currentPageTitle: String? {
        guard let title = webView.title, !title.isEmpty else { return nil }
        return title
    }

    func load(_ url: URL) {
        SnifferBridge.shared.reset()
        isLoading = true
        pageReady = false
        loadErrorMessage = nil
        pageMatchesRule = activeParser(for: url) != nil
        lastLoadURL = url
        isUserInitiatedLoad = true
        applyUserAgent(for: url)
        LogStore.shared.info("open \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    /// 重新加载最近一次地址（失败提示里的「重试」）。
    func retryLastLoad() {
        guard let url = lastLoadURL else { return }
        load(url)
    }

    /// 用户已看过提示，清掉失败原因。
    func clearLoadError() {
        loadErrorMessage = nil
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
        LogStore.shared.info("parsed \(variants.count) variant(s) on \(pageURL.absoluteString)")
        // 历史在「真正入队下载」时记录（见 DownloadManager.enqueue），
        // 只解析不下载、或下载被取消，都不该在历史里留下记录。
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
        loadErrorMessage = nil
        currentURL = webView.url
        pageMatchesRule = activeParser(for: webView.url) != nil
    }

    /// 页面开始渲染时地址已基本确定（含重定向后的地址），此时同步地址栏。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        currentURL = webView.url
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        pageReady = true
        pageMatchesRule = activeParser(for: webView.url) != nil
        isUserInitiatedLoad = false
        currentURL = webView.url
        if let url = webView.url {
            LogStore.shared.info("loaded \(url.absoluteString)")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        pageReady = false
        pageMatchesRule = activeParser(for: webView.url) != nil
        isUserInitiatedLoad = false
        recordLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        pageReady = false
        pageMatchesRule = activeParser(for: webView.url) != nil
        isUserInitiatedLoad = false
        recordLoadFailure(error)
    }

    /// 记录导航失败原因。
    ///
    /// 主动取消（页面里又发起了新跳转）与「被策略中断」都不是真的失败，不提示。
    private func recordLoadFailure(_ error: Error) {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }

        loadErrorMessage = nsError.localizedDescription
        LogStore.shared.error("load failed \(lastLoadURL?.absoluteString ?? "-"): \(nsError.localizedDescription)")
    }

    /// 注入到每个页面：把 SPA 换页后的新地址上报上来。
    private static func pageURLUserScript() -> WKUserScript {
        let source = [
            "(function () {",
            "  if (window.top !== window) { return; }",
            "  if (window.__noxURLHook) { return; }",
            "  window.__noxURLHook = true;",
            "  var last = location.href;",
            "  function report() {",
            "    if (location.href === last) { return; }",
            "    last = location.href;",
            "    try { window.webkit.messageHandlers.\(PageURLBridge.handlerName).postMessage(String(location.href)); } catch (e) {}",
            "  }",
            "  ['pushState', 'replaceState'].forEach(function (name) {",
            "    var original = history[name];",
            "    if (typeof original !== 'function') { return; }",
            "    history[name] = function () {",
            "      var result = original.apply(this, arguments);",
            "      report();",
            "      return result;",
            "    };",
            "  });",
            "  window.addEventListener('popstate', report);",
            "  window.addEventListener('hashchange', report);",
            "  setInterval(report, 800);",
            "})();"
        ].joined(separator: "\n")

        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// 让 YouTube 走桌面 UA、其他站点走移动 Safari UA。
    ///
    /// 移动版 YouTube 的服务端渲染页在 `ytInitialPlayerResponse` 里只给
    /// `signatureCipher`（没有可直链的 `url`）；桌面版才会内联好签名的直链。
    /// 根目录的 `youtube.js` 从不做解密、只挑带 `url` 的格式，它能在浏览器里
    /// 工作靠的就是这一点。这里只对 YouTube 换 UA，其他站点保持移动版，
    /// 免得又被判定成机器人。
    private func applyUserAgent(for url: URL) {
        let userAgent = Self.isYouTubeHost(url) ? Self.desktopUserAgent : Self.safariUserAgent
        if webView.customUserAgent != userAgent {
            webView.customUserAgent = userAgent
        }
    }

    private static func isYouTubeHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domains = ["youtube.com", "youtube-nocookie.com", "youtu.be"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 桌面版 Chrome UA：YouTube 桌面页会内联带签名的直链。
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// 移动版 Safari 的完整 User-Agent，供 WebView 使用。
    private static var safariUserAgent: String {
        let version = UIDevice.current.systemVersion
        let osVersion = version.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVersion) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) "
            + "Mobile/15E148 Safari/604.1"
    }
}
/// 接收页面里 SPA 换页（pushState / replaceState / popstate）上报的地址。
///
/// WKUserContentController 会强持有它；onURLChange 用 [weak self] 回指
/// VideoParser，不会造成循环引用。
@MainActor
final class PageURLBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "noxPageURL"

    var onURLChange: ((URL) -> Void)?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName else { return }
        guard let raw = message.body as? String, let url = URL(string: raw) else { return }
        onURLChange?(url)
    }
}
