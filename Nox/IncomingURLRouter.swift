import Combine
import Foundation
import UIKit
import NoxCore

/// 统一接收系统交给 App 的 URL。
///
/// `.onOpenURL` 对 URL Scheme（分享扩展回传的 `nox://…`）很可靠，但
/// “从其他 App 用 Nox 打开文件”属于 document open，在部分 iOS 版本上
/// 不会走 `.onOpenURL`；SwiftUI 又使用 UIScene 生命周期，冷启动时
/// `application(_:open:options:)` 同样可能不会被调用。
///
/// 这里把三条入口汇到同一个中心：
/// - `application(_:open:options:)`（热启动）
/// - `UIScene.connectionOptions`（冷启动，URL 只出现在这里）
/// - `.onOpenURL`（SwiftUI 正常路径）
///
/// 并按 URL + 时间做去重，避免同一次打开被导入多次。
@MainActor
final class IncomingURLCenter: ObservableObject {
    static let shared = IncomingURLCenter()

    @Published private(set) var pendingURL: URL?

    private var lastKey = ""
    private var lastTime = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private init() {
        // SwiftUI App 没有自己的 SceneDelegate，冷启动时系统把「打开链接 /
        // 打开文件」放进 `scene.connectionOptions.urlContexts`。在 scene 连接
        // 通知里补读一次，避免外部导入因为生命周期拿不到 URL 而静默失败。
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIScene.willConnectNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // UIScene 的属性是 main-actor 隔离的，统一跳回主线程读取。
                Task { @MainActor [weak self] in
                    guard let scene = notification.object as? UIScene else { return }
                    let urls = scene.connectionOptions.urlContexts.map(\.url)
                    guard !urls.isEmpty else { return }

                    for url in urls {
                        self?.submit(url, source: "scene")
                    }
                }
            }
        )
    }

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

/// SwiftUI 生命周期下的 App 代理：只负责接收 document open 等
/// `application(_:open:options:)` 事件，再交给 `IncomingURLCenter`。
@MainActor
final class NoxAppDelegate: NSObject, UIApplicationDelegate {
    override init() {
        super.init()
        // Scene 连接通知可能早于 ContentView 创建，这里提前建立监听。
        _ = IncomingURLCenter.shared
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        IncomingURLCenter.shared.submit(url, source: "delegate")
        return true
    }
}
