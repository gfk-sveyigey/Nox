import Foundation
import WebKit
import NoxCore

/// 站点解析器需要的页面能力。用协议隔开，解析规则不必知道 WKWebView 的存在。
@MainActor
public protocol WebPageContext: AnyObject {
    var pageURL: URL? { get }
    var userAgent: String? { get }

    /// 在页面里执行 JS
    func evaluate(_ script: String) async throws -> Any?

    /// 在页面里执行一段**可返回 Promise** 的 JS 并等它完成。
    ///
    /// `evaluate` 走的是同步通道，拿到 Promise 只会得到空值（不能 await），
    /// 像「在页面里 fetch 播放器脚本再解密」这种异步逻辑就必须用它。
    func evaluateAsync(_ body: String, arguments: [String: Any]) async throws -> Any?

    /// 取与某个地址相关的 Cookie 头
    func cookieHeader(matching url: URL?) async -> String?

    /// 页面标题
    func documentTitle() async -> String?
}

@MainActor
public final class WKWebPageContext: WebPageContext {
    private let webView: WKWebView

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public var pageURL: URL? { webView.url }
    public var userAgent: String? { webView.customUserAgent }

    public func evaluate(_ script: String) async throws -> Any? {
        do {
            return try await webView.evaluateJavaScript(script)
        } catch {
            throw ParserError.scriptFailed(error.localizedDescription)
        }
    }

    public func evaluateAsync(_ body: String, arguments: [String: Any]) async throws -> Any? {
        do {
            // .page 内容世界 = 页面主世界；不然读不到 ytcfg / 播放器脚本这些页面全局。
            return try await webView.callAsyncJavaScript(
                body,
                arguments: arguments,
                contentWorld: .page
            )
        } catch {
            throw ParserError.scriptFailed(error.localizedDescription)
        }
    }

    public func documentTitle() async -> String? {
        (try? await webView.evaluateJavaScript("document.title")) as? String
    }

    public func cookieHeader(matching url: URL?) async -> String? {
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
