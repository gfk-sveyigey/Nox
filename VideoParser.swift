import Foundation
import WebKit

@MainActor
final class VideoParser: NSObject, ObservableObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[VideoVariant], Error>?

    func parse(pageURL: URL) async throws -> [VideoVariant] {
        guard pageURL.scheme == "http" || pageURL.scheme == "https" else {
            throw ParserError.invalidURL
        }

        if let old = webView {
            old.stopLoading()
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.isHidden = true
        webView = view

        let request = URLRequest(
            url: pageURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )

        view.load(request)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.finish(.failure(ParserError.pageLoadFailed))
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.finish(.failure(ParserError.pageLoadFailed))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let javascript = """
        (() => {
            const keys = Object.keys(window).filter(k => k.startsWith('flashvars_'));
            if (!keys.length) return JSON.stringify({error:'no_flashvars'});

            for (const key of keys) {
                try {
                    const value = window[key];
                    if (value && Array.isArray(value.mediaDefinitions)) {
                        return JSON.stringify({
                            mediaDefinitions: value.mediaDefinitions
                        });
                    }
                } catch (_) {}
            }
            return JSON.stringify({error:'no_mediaDefinitions'});
        })()
        """

        webView.evaluateJavaScript(javascript) { [weak self] result, error in
            guard let self else { return }

            Task { @MainActor in
                if error != nil {
                    self.finish(.failure(ParserError.mediaDefinitionsNotFound))
                    return
                }

                guard let string = result as? String,
                      let data = string.data(using: .utf8) else {
                    self.finish(.failure(ParserError.mediaDefinitionsNotFound))
                    return
                }

                do {
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                    if let error = object?["error"] as? String {
                        switch error {
                        case "no_flashvars", "no_mediaDefinitions":
                            self.finish(.failure(ParserError.mediaDefinitionsNotFound))
                        default:
                            self.finish(.failure(ParserError.mediaDefinitionsNotFound))
                        }
                        return
                    }

                    guard let definitions = object?["mediaDefinitions"] as? [[String: Any]] else {
                        self.finish(.failure(ParserError.mediaDefinitionsNotFound))
                        return
                    }

                    guard let remoteString = definitions.first(where: {
                        ($0["remote"] as? Bool) == true
                    })?["videoUrl"] as? String,
                    let remoteURL = URL(string: remoteString) else {
                        self.finish(.failure(ParserError.remoteURLNotFound))
                        return
                    }

                    Task {
                        do {
                            let variants = try await self.fetchRemoteVariants(
                                remoteURL: remoteURL,
                                referer: webView.url
                            )
                            self.finish(.success(variants))
                        } catch {
                            self.finish(.failure(error))
                        }
                    }
                } catch {
                    self.finish(.failure(ParserError.mediaDefinitionsNotFound))
                }
            }
        }
    }

    private func fetchRemoteVariants(remoteURL: URL,
                                     referer: URL?) async throws -> [VideoVariant] {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ParserError.remoteResponseInvalid
        }

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ParserError.remoteResponseInvalid
        }

        var result: [VideoVariant] = []

        for item in array {
            guard let videoURLString = item["videoUrl"] as? String,
                  let videoURL = URL(string: videoURLString) else {
                continue
            }

            let quality = String(describing: item["quality"] ?? "unknown")
            let format = String(describing: item["format"] ?? "mp4")

            result.append(
                VideoVariant(
                    quality: quality,
                    format: format,
                    url: videoURL
                )
            )
        }

        guard !result.isEmpty else {
            throw ParserError.noVideoVariants
        }

        return result
    }

    private func finish(_ result: Result<[VideoVariant], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
