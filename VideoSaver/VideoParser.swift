import Foundation
import WebKit

@MainActor
final class VideoParser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var isLoading = false

    private let webView: WKWebView
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    var browserWebView: WKWebView { webView }

    func load(_ url: URL) {
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    func parseCurrentPage() async throws -> ParsedVideo {
        guard let pageURL = webView.url else { throw ParserError.invalidURL }
        isLoading = true
        defer { isLoading = false }

        let payload = try await evaluateExtractionScript()
        guard let mediaDefinitions = payload["mediaDefinitions"] as? [[String: Any]] else {
            throw ParserError.noMediaDefinitions
        }

        guard let remote = mediaDefinitions.first(where: {
            if let value = $0["remote"] as? Bool { return value }
            if let value = $0["remote"] as? String { return value == "true" }
            return false
        }), let remoteAddress = remote["videoUrl"] as? String, let remoteURL = URL(string: remoteAddress) else {
            throw ParserError.noRemoteManifest
        }

        let cookies = await cookieHeaderForCurrentPage()
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        if let cookieHeader = cookies { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if let userAgent = webView.customUserAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ParserError.manifestRequestFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParserError.manifestRequestFailed("HTTP \(http.statusCode)")
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let items = object as? [[String: Any]] else { throw ParserError.invalidManifest }
        let variants = items.compactMap { item -> VideoVariant? in
            guard let urlString = item["videoUrl"] as? String, let url = URL(string: urlString) else { return nil }
            let quality = String(describing: item["quality"] ?? "")
            let format = String(describing: item["format"] ?? "")
            return VideoVariant(quality: quality, format: format, url: url)
        }
        guard !variants.isEmpty else { throw ParserError.noVideoVariants }

        let title = await currentTitle() ?? pageURL.host ?? "Video"
        appState.addHistory(title: title, url: pageURL)
        return ParsedVideo(title: title, pageURL: pageURL, variants: variants)
    }

    private func evaluateExtractionScript() async throws -> [String: Any] {
        let script = #"""
        (() => {
          const keys = Object.getOwnPropertyNames(window).filter(k => k.startsWith('flashvars_'));
          if (!keys.length) return {error: 'no_flashvars'};
          for (const key of keys) {
            try {
              const value = window[key];
              if (value && Array.isArray(value.mediaDefinitions)) {
                return {mediaDefinitions: value.mediaDefinitions};
              }
            } catch (_) {}
          }
          return {error: 'no_mediaDefinitions'};
        })()
        """
        let value = try await webView.evaluateJavaScript(script)
        guard let dict = value as? [String: Any] else { throw ParserError.noMediaDefinitions }
        if dict["error"] != nil { throw ParserError.noMediaDefinitions }
        return dict
    }

    private func currentTitle() async -> String? {
        (try? await webView.evaluateJavaScript("document.title")) as? String
    }

    func cookieHeaderForCurrentPage() async -> String? {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let relevant = cookies.filter { cookie in
                    guard let host = self.webView.url?.host else { return false }
                    return host == cookie.domain || host.hasSuffix(cookie.domain)
                }
                let value = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                continuation.resume(returning: value.isEmpty ? nil : value)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}
