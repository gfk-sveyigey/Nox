import Foundation
import WebKit

/// 把剪裁后的嗅探脚本包装成 `WKUserScript`。
enum SnifferScript {
    static let resourceName = "MediaSniffer"
    static let resourceExtension = "js"

    /// 脚本随包分发（作为 Resources 加入 target），便于单独维护与替换
    static func source() -> String {
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) else {
            return ""
        }

        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// - `forMainFrameOnly: false` 让跨域 iframe 也注入 —— 它们各自把资源
    ///   `postMessage` 上来，比浏览器里的 `@noframes` 覆盖面更大。
    /// - `atDocumentStart` 是为了尽早挂上 XHR / fetch 钩子，否则页面在
    ///   `documentEnd` 之前发出的 m3u8 请求会被漏掉（DOM 扫描不受影响，
    ///   它由脚本内部的 `DOMContentLoaded` / `load` / 定时器触发）。
    static func userScript() -> WKUserScript? {
        let body = source()
        guard !body.isEmpty else { return nil }

        return WKUserScript(
            source: body,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
}