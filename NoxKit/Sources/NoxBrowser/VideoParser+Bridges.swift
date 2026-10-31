import Foundation
import UIKit
import WebKit
import NoxCore
import NoxParsing

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
