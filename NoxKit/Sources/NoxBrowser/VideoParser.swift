import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxParsing


/// 浏览器宿主 + 解析调度。具体站点的规则由 `VideoSiteParser` 实现。
@MainActor
public final class VideoParser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published public private(set) var isLoading = false
    /// 当前页面的加载进度（0…1），来自 `WKWebView.estimatedProgress`。
    ///
    /// 地址栏用它画一条细进度条：在页面里点链接换页时，页面区域还停在旧页面上，
    /// 只有这条进度条能立刻告诉用户「新页面正在加载」。
    @Published public private(set) var loadProgress: Double = 0
    /// 是否正在「同一文档内换页」（SPA 的 pushState / replaceState / popstate）。
    ///
    /// 这类换页**不触发任何导航回调**：`isLoading` 与 `estimatedProgress` 都不会变，
    /// 页面区域也还停在旧内容上。地址栏只能靠页面上报的这个标记给出加载反馈。
    @Published public private(set) var isSameDocumentLoading = false
    @Published public private(set) var pageMatchesRule = false
    @Published public private(set) var pageReady = false
    /// WebView 当前地址。地址栏用它同步「页面内跳转 / 重定向」后的新地址。
    @Published public private(set) var currentURL: URL?
    /// 最近一次导航失败的原因。
    ///
    /// 加载失败时 `WKWebView` 会继续显示上一个页面，用户完全看不出「新地址没打开」，
    /// 视图层会用它在页面区域**直接盖一层错误提示**（不再是弹窗）。
    @Published public private(set) var loadErrorMessage: String?

    /// 最近一次加载是不是「用户主动换页」（地址栏输入 / 历史跳转）。
    ///
    /// 只有这种情况才在换页期间盖一层加载占位，避免「输入了新地址却还显示旧页面」；
    /// 页面内点链接保持浏览器习惯（旧页面留到新页面提交），但失败提示两种都会给。
    @Published public private(set) var isUserInitiatedLoad = false

    /// 最近一次由用户发起的地址，供失败后的「重试」使用。
    public private(set) var lastLoadURL: URL?

    private let webView: WKWebView
    /// 观察 `estimatedProgress`，把加载进度交给地址栏。
    private var progressObservation: NSKeyValueObservation?
    /// 接收页面里 SPA 换页上报的地址（见 pageURLUserScript）。
    private let pageURLBridge: PageURLBridge
    /// 接收页面里「同文档换页是否还在加载」的上报（见 pageURLUserScript）。
    private let pageLoadingBridge: PageLoadingBridge
    private let sites: SiteAvailabilityProviding
    private let registry: VideoSiteParserRegistry

    public init(sites: SiteAvailabilityProviding, registry: VideoSiteParserRegistry = .default) {
        self.sites = sites
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
        // YouTube 播放时抓已签名的 googlevideo 直链（详见 youtubeMediaUserScript）。
        configuration.userContentController.addUserScript(Self.youtubeMediaUserScript())
        let pageURLBridge = PageURLBridge()
        configuration.userContentController.add(pageURLBridge, name: PageURLBridge.handlerName)
        // 同文档换页的加载状态：导航回调完全不会为它触发，只能靠页面脚本上报。
        let pageLoadingBridge = PageLoadingBridge()
        configuration.userContentController.add(pageLoadingBridge, name: PageLoadingBridge.handlerName)

        self.pageURLBridge = pageURLBridge
        self.pageLoadingBridge = pageLoadingBridge
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        pageURLBridge.onURLChange = { [weak self] url in
            self?.currentURL = url
        }
        pageLoadingBridge.onLoadingChange = { [weak self] loading in
            self?.isSameDocumentLoading = loading
        }

        // `estimatedProgress` 的 KVO 回调不保证在主线程投递，显式跳回主线程再改状态。
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            let value = webView.estimatedProgress
            Task { @MainActor in self?.loadProgress = value }
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

    public var browserWebView: WKWebView { webView }
    public var canParseCurrentPage: Bool { pageReady && pageMatchesRule && !isLoading }

    /// 当前页面命中的站点名（仅当该站点开关为开启时）
    var currentSiteName: String? { activeParser(for: webView.url)?.displayName }

    /// 当前页面实际生效的解析器标识。
    ///
    /// 视图层用它区分「这条页面是被具名站点接管的，还是靠通用嗅探兜底」——
    /// 具名站点命中时，嗅探入口没有存在意义（解析结果更准，且会重复）。
    public var currentParserIdentifier: String? { activeParser(for: webView.url)?.identifier }

    /// 当前页面地址。
    ///
    /// 从嗅探面板加入下载时，历史记的是**页面**地址而不是媒体地址：
    /// 这样历史页的「跳转网页」能回到原页面，同一页面上的多条资源也不会各占一条记录。
    public var currentPageURL: URL? { webView.url }

    /// 当前页面标题。WKWebView 加载完成后会自动维护，取用无需再执行 JS。
    public var currentPageTitle: String? {
        guard let title = webView.title, !title.isEmpty else { return nil }
        return title
    }

    public func load(_ url: URL) {
        SnifferBridge.shared.reset()
        isLoading = true
        pageReady = false
        loadErrorMessage = nil
        pageMatchesRule = activeParser(for: url) != nil
        lastLoadURL = url
        isUserInitiatedLoad = true
        LogStore.shared.info("open \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    /// 重新加载最近一次地址（失败提示里的「重试」）。
    public func retryLastLoad() {
        guard let url = lastLoadURL else { return }
        load(url)
    }

    /// 用户已看过提示，清掉失败原因。
    public func clearLoadError() {
        loadErrorMessage = nil
    }

    public func parseCurrentPage() async throws -> ParsedVideo {
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
    public func cookieHeaderForCurrentPage() async -> String? {
        await WKWebPageContext(webView: webView).cookieHeader(matching: webView.url)
    }

    /// 让页面里的嗅探脚本立刻重扫一遍（对应原脚本的「重新扫描」按钮）。
    /// 返回本次新上报的条数。
    @discardableResult
    public func rescanPage(deep: Bool = true) async -> Int {
        let script = "window.__MS_SNIFF__ ? window.__MS_SNIFF__(\(deep)) : 0"
        let value = try? await webView.evaluateJavaScript(script)
        return (value as? Int) ?? 0
    }

    // MARK: - 站点开关

    /// 匹配站点规则 **且** 该站点在设置页处于开启状态
    private func activeParser(for url: URL?) -> VideoSiteParser? {
        guard let url else { return nil }
        return registry.parsers.first {
            sites.isSiteEnabled($0.identifier) && $0.canHandle(url)
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // 换页清空上一页的嗅探结果
        SnifferBridge.shared.reset()
        isLoading = true
        pageReady = false
        loadErrorMessage = nil
        // 真正的换页（新文档）开始：旧文档连同它的脚本一起没了，
        // 同文档换页的标记不可能再收到「结束」上报，必须在这里清掉。
        isSameDocumentLoading = false
        currentURL = webView.url
        pageMatchesRule = activeParser(for: webView.url) != nil
    }

    /// 页面开始渲染时地址已基本确定（含重定向后的地址），此时同步地址栏。
    ///
    /// 同时重算命中规则：手势后退 / 前进不一定走完整的 `didStartProvisional`
    /// 流程，只靠 `didFinish` 容易出现「回到上一页后解析入口不出现」。
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        currentURL = webView.url
        pageMatchesRule = activeParser(for: webView.url) != nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        pageReady = true
        pageMatchesRule = activeParser(for: webView.url) != nil
        isUserInitiatedLoad = false
        isSameDocumentLoading = false
        currentURL = webView.url
        if let url = webView.url {
            LogStore.shared.info("loaded \(url.absoluteString)")
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        pageReady = pageReadyAfterFailure(error)
        pageMatchesRule = activeParser(for: webView.url) != nil
        isUserInitiatedLoad = false
        recordLoadFailure(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        pageReady = pageReadyAfterFailure(error)
        pageMatchesRule = activeParser(for: webView.url) != nil
        isUserInitiatedLoad = false
        recordLoadFailure(error)
    }

    /// 失败 / 取消之后该不该认为页面仍然可用。
    ///
    /// 手势后退 / 前进常伴随一次「被取消的临时导航」：页面并没有真的离开。
    /// 若一律把 `pageReady` 置 false，解析入口会一直不出现（直到下一次完整加载），
    /// 表现为「返回上一页后不解析」。这里按 WebView 的真实状态恢复。
    private func pageReadyAfterFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        guard cancelled else { return false }
        return webView.url != nil && !webView.isLoading
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

    /// 移动版 Safari 的完整 User-Agent，供 WebView 使用。
    private static var safariUserAgent: String {
        let version = UIDevice.current.systemVersion
        let osVersion = version.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVersion) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) "
            + "Mobile/15E148 Safari/604.1"
    }
}
