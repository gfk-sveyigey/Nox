import Combine
import Foundation
import UIKit
import NoxCore

/// 统一接收系统交给 App 的 URL。
///
/// App 现在使用自定义的 `NoxSceneDelegate`，冷启动的 URL 来自
/// `connectionOptions`、热启动来自 `scene(_:openURLContexts:)`；
/// `ContentView` 的 `.onOpenURL` 仍保留为额外入口。所有来源都汇入这里，
/// 并按 URL + 时间做去重，避免同一次打开被导入多次。
///
/// 如果系统既没有回调 scene 也没有把文件交给 App，`ContentView` 还会
/// 兜底扫描 `Documents/Inbox`（见导入协调器）。
@MainActor
final class IncomingURLCenter: ObservableObject {
    static let shared = IncomingURLCenter()

    @Published private(set) var pendingURL: URL?

    private var lastKey = ""
    private var lastTime = Date.distantPast

    private init() {}

    func submit(_ url: URL, source: String = "app") {
        let key = url.absoluteString
        let now = Date()
        if key == lastKey, now.timeIntervalSince(lastTime) < 2 {
            LogStore.shared.info("incoming url duplicate ignored (\(source))")
            return
        }

        lastKey = key
        lastTime = now
        pendingURL = url

        LogStore.shared.info("incoming url (\(source)): \(Self.describe(url))")
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
