import Combine
import Foundation
import UIKit
import NoxCore

/// 统一接收系统交给 App 的 URL。
///
/// `.onOpenURL` 对 URL Scheme（分享扩展回传的 `nox://…`）很可靠，但
/// “从其他 App 用 Nox 打开文件”属于 document open，在部分 iOS 版本上
/// 不会走 `.onOpenURL`。这里再加一层 `UIApplicationDelegate` 兜底，
/// 两条路径都汇入同一个中心，并按 URL + 时间做去重，避免重复导入。
@MainActor
final class IncomingURLCenter: ObservableObject {
    static let shared = IncomingURLCenter()

    @Published private(set) var pendingURL: URL?

    private var lastKey = ""
    private var lastTime = Date.distantPast

    private init() {}

    func submit(_ url: URL) {
        let key = url.absoluteString
        let now = Date()
        if key == lastKey, now.timeIntervalSince(lastTime) < 2 {
            LogStore.shared.info("incoming url duplicate ignored")
            return
        }

        lastKey = key
        lastTime = now
        pendingURL = url

        LogStore.shared.info("incoming url: \(Self.describe(url))")
    }

    /// 只在仍是同一个 URL 时清空，避免把紧接着到达的新 URL 一起吞掉。
    func consume(_ url: URL) {
        guard pendingURL == url else { return }
        pendingURL = nil
    }

    private static func describe(_ url: URL) -> String {
        if url.isFileURL {
            return "file \(url.lastPathComponent)"
        }

        let text = url.absoluteString
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}

/// SwiftUI 生命周期下的 App 代理：只负责接收 document open 等
/// `application(_:open:options:)` 事件，再交给 `IncomingURLCenter`。
@MainActor
final class NoxAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        IncomingURLCenter.shared.submit(url)
        return true
    }
}
