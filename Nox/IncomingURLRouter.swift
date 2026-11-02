import Combine
import Foundation
import UIKit
import NoxCore

/// 统一接收系统交给 App 的 URL。
///
/// App 使用自定义的 `NoxSceneDelegate`：冷启动的 URL 来自
/// `connectionOptions`、热启动来自 `scene(_:openURLContexts:)`；
/// `ContentView` 的 `.onOpenURL` 仍保留为额外入口。所有来源都汇入这里。
///
/// 文件 URL 不能只依赖 `ContentView` 的 `pendingURL`：冷启动时系统可能在
/// SwiftUI 首次渲染前就送达文件，此时直接弹 Alert 会被系统丢弃，看起来就是
/// 「跳转到 Nox 但没有导入」。因此文件先进入队列，等界面就绪且 App 在前台
/// 后再交给导入协调器。网页链接仍通过 `pendingURL` 驱动浏览器跳转。
@MainActor
final class IncomingURLCenter: ObservableObject {
    static let shared = IncomingURLCenter()

    @Published private(set) var pendingURL: URL?

    private var lastKey = ""
    private var lastTime = Date.distantPast
    private var isUIReady = false
    private var deferredFileURLs: [URL] = []

    private init() {}

    func submit(_ url: URL, source: String = "app") {
        LogStore.shared.info("incoming url (\(source)): \(Self.describe(url))")

        if url.isFileURL {
            enqueueFileImport(url)
            return
        }

        let key = url.absoluteString
        let now = Date()
        if key == lastKey, now.timeIntervalSince(lastTime) < 2 {
            LogStore.shared.info("incoming url duplicate ignored (\(source))")
            return
        }

        lastKey = key
        lastTime = now
        pendingURL = url
    }

    /// 只在仍是同一个 URL 时清空，避免把紧接着到达的新 URL 一起吞掉。
    func consume(_ url: URL) {
        guard pendingURL == url else { return }
        pendingURL = nil
    }

    /// `ContentView` 首次渲染完成后调用。此前的文件打开先排队，
    /// 确保 `.alert` 已经挂到视图树上。
    func markUIReady() {
        isUIReady = true
        // 等当前渲染周期结束，确保 `.alert(item:)` 已经挂到视图树上。
        DispatchQueue.main.async { [weak self] in
            self?.deliverDeferredFileImports()
        }
    }

    /// scene 回到前台时补一次：文件可能在 App 仍处于后台时送达。
    func sceneDidBecomeActive() {
        deliverDeferredFileImports()
    }

    private func enqueueFileImport(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !deferredFileURLs.contains(where: {
            $0.standardizedFileURL.path == path
        }) else { return }

        deferredFileURLs.append(url)
        LogStore.shared.info("file open queued: \(url.lastPathComponent)")
        deliverDeferredFileImports()
    }

    private func deliverDeferredFileImports() {
        guard
            isUIReady,
            UIApplication.shared.applicationState == .active,
            !deferredFileURLs.isEmpty
        else { return }

        let urls = deferredFileURLs
        deferredFileURLs.removeAll()
        LogStore.shared.info("delivering \(urls.count) queued file open(s)")
        for url in urls {
            PluginImportCoordinator.shared.handleOpenURL(url)
        }
    }

    private static func describe(_ url: URL) -> String {
        if url.isFileURL {
            return "file \(url.lastPathComponent)"
        }

        let text = url.absoluteString
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}
