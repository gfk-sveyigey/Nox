import Foundation
import UIKit
import WebKit
import NoxCore


/// 单个 `.noxplugin` 的 JavaScript 运行时。
///
/// 插件代码运行在独立的隐藏 `WKWebView` 中；页面 DOM / Cookie / 网络请求
/// 全部通过消息桥交回原生执行。这样插件死循环只会影响自己的 WebContent 进程。
@MainActor
final class PluginRuntime: NSObject {
    private static let handlerName = "nox"
    private static let maxResponseBytes = 16 * 1024 * 1024
    private static let maxTotalBytes = 32 * 1024 * 1024
    private static let maxRequests = 50

    private let manifest: PluginManifest
    private let source: String

    private var webView: WKWebView?
    private var messageHandler: PluginMessageHandler?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var prepareTask: Task<Void, Error>?
    private var isPrepared = false
    private var isParsing = false
    private var currentPage: WebPageContext?
    private var requestCount = 0
    private var totalDownloadedBytes = 0

    init(manifest: PluginManifest, source: String) {
        self.manifest = manifest
        self.source = source
        super.init()
    }

    func parse(page: WebPageContext) async throws -> [VideoVariant] {
        guard !isParsing else {
            throw PluginError.executionFailed("同一插件不支持并发解析")
        }

        isParsing = true
        currentPage = page
        requestCount = 0
        totalDownloadedBytes = 0
        defer {
            isParsing = false
            currentPage = nil
        }

        try await ensurePrepared()

        guard let webView else {
            throw PluginError.executionFailed("插件运行时不可用")
        }

        let contextJSON = try Self.contextJSON(for: page)
        _ = try await webView.callAsyncJavaScript(
            "window.__noxContext = JSON.parse(json)",
            arguments: ["json": contextJSON],
            contentWorld: .page
        )

        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                "return await window.__noxParse()",
                arguments: [:],
                contentWorld: .page
            )
        } catch {
            throw PluginError.executionFailed(error.localizedDescription)
        }

        return try Self.decode(raw)
    }

    // MARK: - 装载

    private func ensurePrepared() async throws {
        if isPrepared { return }

        if let prepareTask {
            try await prepareTask.value
            return
        }

        let task = Task { @MainActor in
            try await self.loadAndInstall()
        }
        prepareTask = task

        do {
            try await task.value
            isPrepared = true
            prepareTask = nil
        } catch {
            prepareTask = nil
            tearDown()
            throw error
        }
    }

    private func loadAndInstall() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let handler = PluginMessageHandler(runtime: self)
        configuration.userContentController.add(handler, name: Self.handlerName)
        messageHandler = handler

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1, height: 1),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        self.webView = webView

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadHTMLString(Self.harnessHTML, baseURL: nil)
        }
    }

    private func finishLoad() async {
        guard let continuation = loadContinuation, let webView else { return }
        loadContinuation = nil

        do {
            _ = try await webView.evaluateJavaScript(source)
            let value = try await webView.evaluateJavaScript(
                "!!window.__noxDefinition"
            )
            let registered = (value as? NSNumber)?.boolValue ?? false
            guard registered else {
                throw PluginError.executionFailed("插件没有调用 Nox.register")
            }
            continuation.resume()
        } catch {
            continuation.resume(
                throwing: PluginError.executionFailed(error.localizedDescription)
            )
        }
    }

    private func failLoad(_ error: Error) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(
            throwing: PluginError.executionFailed(error.localizedDescription)
        )
    }

    private func tearDown() {
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: Self.handlerName
            )
        }
        webView = nil
        messageHandler = nil
        isPrepared = false
    }

    // MARK: - JavaScript → Native

    fileprivate func handleMessage(_ body: Any) {
        guard let message = body as? [String: Any],
              let method = message["method"] as? String else {
            return
        }

        let id = (message["id"] as? NSNumber)?.intValue
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "log":
            handleLog(id: id, params: params)
        case "page.eval":
            handlePageEval(id: id, params: params)
        case "page.title":
            handlePageTitle(id: id)
        case "cookies":
            handleCookies(id: id, params: params)
        case "http.request":
            handleHTTPRequest(id: id, params: params)
        default:
            reject(id, "未知插件调用：\(method)")
        }
    }

    private func handleLog(id: Int?, params: [String: Any]) {
        guard manifest.permissions.contains("log") else {
            reject(id, "插件没有 log 权限")
            return
        }

        let level = (params["level"] as? String ?? "info").lowercased()
        let message = params["message"] as? String ?? ""
        let line = "[plugin:\(manifest.id)] \(message)"

        switch level {
        case "error": LogStore.shared.error(line)
        case "warning", "warn": LogStore.shared.warning(line)
        default: LogStore.shared.info(line)
        }
        resolve(id, value: NSNull())
    }

    private func handlePageEval(id: Int?, params: [String: Any]) {
        guard manifest.permissions.contains("page.eval") else {
            reject(id, "插件没有 page.eval 权限")
            return
        }
        guard let page = currentPage else {
            reject(id, "当前没有可用的页面")
            return
        }

        let script = params["script"] as? String ?? ""
        guard !script.isEmpty else {
            resolve(id, value: NSNull())
            return
        }

        Task { @MainActor in
            do {
                let value = try await page.evaluateAsync(
                    "return await (\(script))",
                    arguments: [:]
                )
                self.resolve(id, value: value)
            } catch {
                self.reject(id, error.localizedDescription)
            }
        }
    }

    private func handlePageTitle(id: Int?) {
        guard manifest.permissions.contains("page.title") else {
            reject(id, "插件没有 page.title 权限")
            return
        }
        guard let page = currentPage else {
            reject(id, "当前没有可用的页面")
            return
        }

        Task { @MainActor in
            let title = await page.documentTitle()
            self.resolve(id, value: title.map { $0 as Any } ?? NSNull())
        }
    }

    private func handleCookies(id: Int?, params: [String: Any]) {
        guard manifest.permissions.contains("cookies") else {
            reject(id, "插件没有 cookies 权限")
            return
        }
        guard let page = currentPage else {
            reject(id, "当前没有可用的页面")
            return
        }

        let url = (params["url"] as? String).flatMap(URL.init(string:)) ?? page.pageURL
        Task { @MainActor in
            let value = await page.cookieHeader(matching: url) ?? ""
            self.resolve(id, value: value)
        }
    }

    private func handleHTTPRequest(id: Int?, params: [String: Any]) {
        guard manifest.permissions.contains("http") else {
            reject(id, "插件没有 http 权限")
            return
        }
        guard requestCount < Self.maxRequests else {
            reject(id, "单次解析最多允许 \(Self.maxRequests) 个网络请求")
            return
        }
        guard let page = currentPage else {
            reject(id, "当前没有可用的页面")
            return
        }
        guard let urlString = params["url"] as? String,
              let url = URL(string: urlString),
              manifest.allowsNetwork(url) else {
            reject(id, "网络地址不在插件允许列表内")
            return
        }

        requestCount += 1

        let method = (params["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method) else {
            reject(id, "不支持的 HTTP 方法：\(method)")
            return
        }

        let useCookies = (params["useCookies"] as? NSNumber)?.boolValue ?? false
        guard !useCookies || manifest.permissions.contains("cookies") else {
            reject(id, "插件没有 cookies 权限")
            return
        }

        let timeout = min(max((params["timeoutMs"] as? NSNumber)?.intValue ?? 20_000, 1_000), 30_000)
        let responseType = params["responseType"] as? String ?? "text"

        Task { @MainActor in
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = TimeInterval(timeout) / 1_000

            if let headers = params["headers"] as? [String: Any] {
                for (name, value) in headers where !name.isEmpty {
                    request.setValue(String(describing: value), forHTTPHeaderField: name)
                }
            }

            if let body = params["body"] as? String, !body.isEmpty {
                request.httpBody = Data(body.utf8)
            }

            if useCookies,
               let cookie = await page.cookieHeader(matching: url),
               !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse else {
                    self.reject(id, "不是有效的 HTTP 响应")
                    return
                }

                if let finalURL = http.url, !self.manifest.allowsNetwork(finalURL) {
                    self.reject(id, "重定向地址不在插件允许列表内")
                    return
                }

                guard data.count <= Self.maxResponseBytes else {
                    self.reject(id, "网络响应超过 16 MiB 限制")
                    return
                }

                self.totalDownloadedBytes += data.count
                guard self.totalDownloadedBytes <= Self.maxTotalBytes else {
                    self.reject(id, "单次解析下载量超过 32 MiB 限制")
                    return
                }

                var headers: [String: String] = [:]
                for (name, value) in http.allHeaderFields {
                    headers[String(describing: name)] = String(describing: value)
                }

                let body: String
                if responseType == "base64" {
                    body = data.base64EncodedString()
                } else {
                    body = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                        ?? ""
                }

                let payload: [String: Any] = [
                    "status": http.statusCode,
                    "url": http.url?.absoluteString ?? url.absoluteString,
                    "headers": headers,
                    "body": body
                ]
                self.resolve(id, value: payload)
            } catch {
                self.reject(id, error.localizedDescription)
            }
        }
    }

    private func resolve(_ id: Int?, value: Any?) {
        guard let id, let webView else { return }

        let validValue: Any = value ?? NSNull()
        let envelope: [String: Any] = ["value": validValue]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else {
            reject(id, "插件返回值无法序列化")
            return
        }

        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                "window.__noxBridge.resolve(id, JSON.parse(json).value)",
                arguments: ["id": id, "json": json],
                contentWorld: .page
            )
        }
    }

    private func reject(_ id: Int?, _ message: String) {
        guard let id, let webView else { return }
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                "window.__noxBridge.reject(id, message)",
                arguments: ["id": id, "message": message],
                contentWorld: .page
            )
        }
    }

    // MARK: - 结果转换

    private static func contextJSON(for page: WebPageContext) throws -> String {
        let url = page.pageURL
        let components = url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""

        let context: [String: Any] = [
            "url": url?.absoluteString ?? "",
            "host": url?.host ?? "",
            "path": url?.path ?? "",
            "query": query,
            "userAgent": page.userAgent.map { $0 as Any } ?? NSNull(),
            "appVersion": appVersion,
            "locale": AppLocale.current.identifier
        ]

        let data = try JSONSerialization.data(withJSONObject: context)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PluginError.executionFailed("无法生成插件上下文")
        }
        return string
    }

    private static func decode(_ raw: Any?) throws -> [VideoVariant] {
        guard let object = raw as? [String: Any],
              let rawVariants = object["variants"] as? [Any] else {
            throw PluginError.executionFailed("插件没有返回 variants")
        }

        guard rawVariants.count <= 100 else {
            throw PluginError.executionFailed("插件返回的清晰度超过 100 项")
        }

        let variants: [VideoVariant] = rawVariants.compactMap { item in
            guard let item = item as? [String: Any],
                  let urlString = item["url"] as? String,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }

            return VideoVariant(
                quality: item["quality"] as? String ?? "",
                format: item["format"] as? String ?? "",
                url: url
            )
        }

        guard !variants.isEmpty else {
            throw ParserError.noVideoVariants
        }
        return variants
    }
}

// MARK: - WKNavigationDelegate

extension PluginRuntime: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        Task { @MainActor [weak self] in
            await self?.finishLoad()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        failLoad(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failLoad(error)
    }
}

// MARK: - 弱引用消息代理

/// `WKUserContentController` 会强持有 handler；用代理避免和 WebView 形成环。
@MainActor
private final class PluginMessageHandler: NSObject, WKScriptMessageHandler {
    weak var runtime: PluginRuntime?

    init(runtime: PluginRuntime) {
        self.runtime = runtime
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        runtime?.handleMessage(message.body)
    }
}

// MARK: - 沙箱页面

private extension PluginRuntime {
    static let harnessHTML = #"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none';">
</head>
<body>
<script>
(function () {
  "use strict";

  var pending = new Map();
  var nextID = 1;

  window.__noxContext = {
    url: "",
    host: "",
    path: "",
    query: {},
    userAgent: null,
    appVersion: "",
    locale: ""
  };

  function send(method, params) {
    return new Promise(function (resolve, reject) {
      var id = nextID++;
      pending.set(id, { resolve: resolve, reject: reject });
      try {
        window.webkit.messageHandlers.nox.postMessage({
          id: id,
          method: method,
          params: params || {}
        });
      } catch (error) {
        pending.delete(id);
        reject(error);
      }
    });
  }

  window.__noxBridge = {
    resolve: function (id, value) {
      var entry = pending.get(id);
      if (entry) {
        pending.delete(id);
        entry.resolve(value);
      }
    },
    reject: function (id, message) {
      var entry = pending.get(id);
      if (entry) {
        pending.delete(id);
        entry.reject(new Error(message));
      }
    }
  };

  window.Nox = {
    apiVersion: 1,
    register: function (definition) {
      if (window.__noxDefinition) {
        throw new Error("Nox.register 只能调用一次");
      }
      window.__noxDefinition = definition;
    },
    log: function (message) {
      send("log", { level: "info", message: String(message) });
    }
  };

  var ctx = {
    get url() { return window.__noxContext.url; },
    get host() { return window.__noxContext.host; },
    get path() { return window.__noxContext.path; },
    get query() { return window.__noxContext.query; },
    get userAgent() { return window.__noxContext.userAgent; },
    get appVersion() { return window.__noxContext.appVersion; },
    get locale() { return window.__noxContext.locale; },
    log: function (level, message) {
      return send("log", { level: String(level), message: String(message) });
    },
    sleep: function (milliseconds) {
      var value = Math.min(Math.max(Number(milliseconds) || 0, 0), 5000);
      return new Promise(function (resolve) { setTimeout(resolve, value); });
    },
    page: {
      eval: function (script) {
        return send("page.eval", { script: String(script) });
      },
      title: function () {
        return send("page.title", {});
      }
    },
    cookies: function (url) {
      return send("cookies", { url: url || null });
    },
    http: {
      request: function (options) {
        return send("http.request", options || {});
      },
      get: function (url, options) {
        return send("http.request", Object.assign({}, options || {}, {
          url: url,
          method: "GET"
        }));
      },
      post: function (url, body, options) {
        return send("http.request", Object.assign({}, options || {}, {
          url: url,
          method: "POST",
          body: body == null ? "" : String(body)
        }));
      }
    }
  };

  window.__noxParse = async function () {
    var definition = window.__noxDefinition;
    if (!definition || typeof definition.parse !== "function") {
      throw new Error("插件没有提供 parse(ctx)");
    }
    return await Promise.race([
      Promise.resolve(definition.parse(ctx)),
      new Promise(function (_, reject) {
        setTimeout(function () {
          reject(new Error("插件解析超时"));
        }, 30000);
      })
    ]);
  };
})();
</script>
</body>
</html>
"""#
}
