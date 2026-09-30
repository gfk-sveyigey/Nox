import Foundation
import WebKit

/// 单个视频站点的解析规则。
///
/// 新增站点：实现本协议 → 在 `VideoSiteParserRegistry.all` 里注册一行即可。
/// 不需要改动 `VideoParser`、`VideoBrowserView` 等任何调用方。
@MainActor
protocol VideoSiteParser: AnyObject {
    /// 稳定标识，用于持久化「站点开关」。
    /// 一经发布就不要改，否则用户已保存的开关状态会失效。
    var identifier: String { get }

    /// 站点展示名，用于设置页与调试提示
    var displayName: String { get }

    /// 是否由本解析器处理该地址（同时决定「解析视频」入口是否可用）
    func canHandle(_ url: URL) -> Bool

    /// 该地址是否落在本站点管辖范围内（只看域名，比 canHandle 宽）。
    ///
    /// canHandle 只对「可解析的具体页面」返回 true（例如 Pornhub 只认
    /// view_video.php），但站点的首页、列表页同样是站内页面 —— 这些页面
    /// 会回落到通用嗅探。视图层用本方法判断「是否站在某个已知站点上」，
    /// 从而避免站内页面同时出现「解析视频」与通用嗅探两个入口。
    func claimsHost(_ url: URL) -> Bool

    /// 在当前页面上抓取可下载的清晰度列表；失败时抛 `ParserError`
    func parse(page: WebPageContext) async throws -> [VideoVariant]
}

/// 站点解析器需要的页面能力。用协议隔开，解析规则不必知道 WKWebView 的存在。
@MainActor
protocol WebPageContext: AnyObject {
    var pageURL: URL? { get }
    var userAgent: String? { get }

    /// 在页面里执行 JS
    func evaluate(_ script: String) async throws -> Any?

    /// 取与某个地址相关的 Cookie 头
    func cookieHeader(matching url: URL?) async -> String?

    /// 页面标题
    func documentTitle() async -> String?
}

@MainActor
final class WKWebPageContext: WebPageContext {
    private let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
    }

    var pageURL: URL? { webView.url }
    var userAgent: String? { webView.customUserAgent }

    func evaluate(_ script: String) async throws -> Any? {
        do {
            return try await webView.evaluateJavaScript(script)
        } catch {
            throw ParserError.scriptFailed(error.localizedDescription)
        }
    }

    func documentTitle() async -> String? {
        (try? await webView.evaluateJavaScript("document.title")) as? String
    }

    func cookieHeader(matching url: URL?) async -> String? {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let host = url?.host
                let relevant = cookies.filter { cookie in
                    guard let host else { return false }
                    return host == cookie.domain || host.hasSuffix(cookie.domain)
                }
                let value = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                continuation.resume(returning: value.isEmpty ? nil : value)
            }
        }
    }
}

// MARK: - 站点解析器可复用的工具

/// 带 Referer / Cookie / User-Agent 的请求，多数站点的清单请求都能直接用。
enum MediaResourceLoader {
    static func fetch(
        url: URL,
        referer: URL?,
        cookieHeader: String?,
        userAgent: String?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")

        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ParserError.manifestRequestFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParserError.manifestRequestFailed("HTTP \(http.statusCode)")
        }

        return data
    }
}

/// 多数站点的清晰度清单都是 `[{ videoUrl, quality, format }]`，抽出来复用。
enum MediaManifestDecoder {
    static func variants(from data: Data) throws -> [VideoVariant] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParserError.invalidManifest
        }

        guard let items = object as? [[String: Any]] else {
            throw ParserError.invalidManifest
        }

        let variants = items.compactMap { item -> VideoVariant? in
            guard let urlString = item["videoUrl"] as? String,
                  let url = URL(string: urlString) else {
                return nil
            }

            return VideoVariant(
                quality: String(describing: item["quality"] ?? ""),
                format: String(describing: item["format"] ?? ""),
                url: url
            )
        }

        guard !variants.isEmpty else { throw ParserError.noVideoVariants }
        return variants
    }
}