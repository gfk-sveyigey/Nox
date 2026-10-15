import Foundation
import UIKit
import WebKit

/// 浏览器宿主 + 解析调度。具体站点的规则由 `VideoSiteParser` 实现。
@MainActor
final class VideoParser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var isLoading = false
    /// 当前页面的加载进度（0…1），来自 `WKWebView.estimatedProgress`。
    ///
    /// 地址栏用它画一条细进度条：在页面里点链接换页时，页面区域还停在旧页面上，
    /// 只有这条进度条能立刻告诉用户「新页面正在加载」。
    @Published private(set) var loadProgress: Double = 0
    /// 是否正在「同一文档内换页」（SPA 的 pushState / replaceState / popstate）。
    ///
    /// 这类换页**不触发任何导航回调**：`isLoading` 与 `estimatedProgress` 都不会变，
    /// 页面区域也还停在旧内容上。地址栏只能靠页面上报的这个标记给出加载反馈。
    @Published private(set) var isSameDocumentLoading = false
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
    /// 观察 `estimatedProgress`，把加载进度交给地址栏。
    private var progressObservation: NSKeyValueObservation?
    /// 接收页面里 SPA 换页上报的地址（见 pageURLUserScript）。
    private let pageURLBridge: PageURLBridge
    /// 接收页面里「同文档换页是否还在加载」的上报（见 pageURLUserScript）。
    private let pageLoadingBridge: PageLoadingBridge
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
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        currentURL = webView.url
        pageMatchesRule = activeParser(for: webView.url) != nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        pageReady = pageReadyAfterFailure(error)
        pageMatchesRule = activeParser(for: webView.url) != nil
        isUserInitiatedLoad = false
        recordLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
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
    private static func pageURLUserScript() -> WKUserScript {
        let source = [
            "(function () {",
            "  if (window.top !== window) { return; }",
            "  if (window.__noxURLHook) { return; }",
            "  window.__noxURLHook = true;",
            "  var last = location.href;",
            "  var lastPath = location.pathname + location.search;",
            "  var navAt = 0;          // 最近一次 URL 变化的时间",
            "  var startedAt = 0;      // 这一轮「同文档加载」开始的时间",
            "  var loadingTimer = null;",
            "  var lastResourceAt = 0;",
            "  var minVisibleMs = 900; // 太短的提示会一闪而过，等于没有提示",
            "  var quietMs = 600;      // 连续这么久没有新的资源请求，就算这一轮结束",
            "  var maxMs = 8000;       // 兜底：再慢也不让提示一直亮着",
            "  var relightMs = 2500;   // 换页后这段时间内到达的资源请求，算作这次换页的",
            "  // 资源请求既刷新「还在加载」的时间戳，也能在慢站点上把提示重新点亮。",
            "  try {",
            "    var observer = new PerformanceObserver(function () {",
            "      lastResourceAt = Date.now();",
            "      if (loadingTimer === null && Date.now() - navAt < relightMs) { beginSameDocumentLoad(); }",
            "    });",
            "    observer.observe({ entryTypes: ['resource'] });",
            "  } catch (e) {}",
            "  function post(name, value) {",
            "    try { window.webkit.messageHandlers[name].postMessage(value); } catch (e) {}",
            "  }",
            "  function reportLoading(loading) {",
            "    post('\(PageLoadingBridge.handlerName)', loading ? 1 : 0);",
            "  }",
            "  // SPA 换页不触发导航回调、也拿不到进度：用「path/query 变了」当作开始，",
            "  // 用「连续一段时间没有新的资源请求」当作结束（另加最短显示时间与 8 秒兜底）。",
            "  function beginSameDocumentLoad() {",
            "    if (loadingTimer !== null) { return; }",
            "    startedAt = Date.now();",
            "    lastResourceAt = startedAt;",
            "    reportLoading(true);",
            "    loadingTimer = setInterval(function () {",
            "      var now = Date.now();",
            "      var elapsed = now - startedAt;",
            "      if (elapsed > maxMs || (elapsed > minVisibleMs && now - lastResourceAt > quietMs)) {",
            "        clearInterval(loadingTimer);",
            "        loadingTimer = null;",
            "        reportLoading(false);",
            "      }",
            "    }, 200);",
            "  }",
            "  function report() {",
            "    if (location.href === last) { return; }",
            "    last = location.href;",
            "    navAt = Date.now();",
            "    post('\(PageURLBridge.handlerName)', String(location.href));",
            "    var path = location.pathname + location.search;",
            "    if (path !== lastPath) {",
            "      lastPath = path;",
            "      beginSameDocumentLoad();",
            "    }",
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

    /// 注入到每个页面：抓 YouTube 播放时请求的 googlevideo 直链。
    ///
    /// YouTube 自己在播放时会去请求**已经签好名**的 `videoplayback` 地址，
    /// 把这些地址记下来，就等于拿到了可以直接下载的直链 —— 不需要签名解密，
    /// 也不需要 PO token。根目录新脚本（ytx-direct-downloader）在独立客户端的
    /// 请求被风控时，靠的就是「让用户先播放几秒，再抓页面自己的媒体请求」这条路。
    ///
    /// 脚本只记 YouTube 域，其他站点上就是个空转的钩子。
    private static func youtubeMediaUserScript() -> WKUserScript {
        let source = #"""
(function () {
  if (window.top !== window) { return; }
  if (window.__noxYTMediaHook) { return; }
  window.__noxYTMediaHook = true;

  var list = window.__noxYTMedia = window.__noxYTMedia || [];
  var seen = Object.create(null);

  function remember(raw) {
    if (!raw) { return; }
    var url;
    try { url = new URL(String(raw), location.href); } catch (e) { return; }
    var host = url.hostname.toLowerCase();
    if (host !== 'googlevideo.com' && host.slice(-16) !== '.googlevideo.com') { return; }
    if (url.pathname.toLowerCase().indexOf('videoplayback') < 0) { return; }
    if (url.searchParams.has('sq')) { return; }
    var itag = Number(url.searchParams.get('itag') || url.searchParams.get('fmt') || 0);
    if (!itag) { return; }
    ['range', 'rn', 'rbuf'].forEach(function (name) { url.searchParams.delete(name); });
    var xtags = url.searchParams.get('xtags') || '';
    var id = url.searchParams.get('id') || url.pathname;
    var key = itag + ':' + xtags + ':' + id;
    var now = Date.now();
    if (seen[key] && now - seen[key] < 8000) { return; }
    seen[key] = now;
    list.push({
      url: url.href,
      itag: itag,
      xtags: xtags,
      mime: String(url.searchParams.get('mime') || '').toLowerCase(),
      clen: Number(url.searchParams.get('clen') || 0)
    });
    if (list.length > 300) { list.splice(0, list.length - 300); }
  }

  function hooked(fn) { return !!(fn && fn.__noxYTMediaHooked); }

  try {
    var originalFetch = window.fetch;
    if (typeof originalFetch === 'function' && !hooked(originalFetch)) {
      var wrappedFetch = function (input) {
        try { remember(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
        var result = originalFetch.apply(this, arguments);
        try {
          Promise.resolve(result).then(function (response) {
            try { remember(response && response.url); } catch (e) {}
            return response;
          });
        } catch (e) {}
        return result;
      };
      wrappedFetch.__noxYTMediaHooked = true;
      window.fetch = wrappedFetch;
    }
  } catch (e) {}

  try {
    var proto = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
    if (proto && typeof proto.open === 'function' && !hooked(proto.open)) {
      var originalOpen = proto.open;
      var wrappedOpen = function (method, url) {
        try { remember(url); } catch (e) {}
        return originalOpen.apply(this, arguments);
      };
      wrappedOpen.__noxYTMediaHooked = true;
      proto.open = wrappedOpen;
    }
  } catch (e) {}

  window.__noxYTMediaRead = function () {
    try {
      var entries = performance.getEntriesByType('resource');
      for (var i = 0; i < entries.length; i++) { remember(entries[i].name); }
    } catch (e) {}
    return window.__noxYTMedia || [];
  };
})();
"""#

        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

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

/// 接收页面里「同一文档内换页（SPA）是否还在加载」的上报。
///
/// 这类换页不触发任何 `WKNavigationDelegate` 回调，`isLoading` / `estimatedProgress`
/// 都不会变；地址栏只有靠它才能在只改 path 的换页上给出加载反馈。
@MainActor
final class PageLoadingBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "noxPageLoading"

    var onLoadingChange: ((Bool) -> Void)?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName else { return }

        // 脚本里 postMessage 的是 0 / 1；两种类型都接住，避免平台差异导致静默失效。
        if let number = message.body as? NSNumber {
            onLoadingChange?(number.boolValue)
        } else if let raw = message.body as? String {
            onLoadingChange?(raw == "1")
        }
    }
}
