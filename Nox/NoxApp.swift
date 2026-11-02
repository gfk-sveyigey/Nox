import SwiftUI
import UIKit
import NoxCore
import NoxDownload
import NoxKeepAlive

/// App 入口。
///
/// 这里刻意使用 UIKit 的 App / Scene 生命周期，而不是 `SwiftUI.App`：
/// `SwiftUI.App` 不暴露 SceneDelegate，冷启动时系统交给 scene 的
/// `connectionOptions`（用其他 App 打开 Nox、分享扩展回传的 `nox://…`）
/// 没有稳定的接收点，`.onOpenURL` 和 `application(_:open:)` 都可能收不到。
/// 自己持有 SceneDelegate 后，冷启动与热启动的 URL 都能拿到。
@main
@MainActor
final class NoxAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 少数系统版本仍会把冷启动 URL 放在 launchOptions 里。
        if let url = launchOptions?[.url] as? URL {
            IncomingURLCenter.shared.submit(url, source: "launch")
        }

        // iOS 26 的持续处理任务必须在启动完成前注册，否则提交时会失败。
        ContinuedProcessingBridge.registerIfNeeded()
        return true
    }

    /// 后台 URLSession 的事件已全部交给代理，通知系统可以结束本次后台唤醒。
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundSessionEvents.shared.store(
            identifier: identifier,
            handler: completionHandler
        )
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // 冷启动时 URL 就挂在这里，先收下来再交给统一的入口中心。
        for context in options.urlContexts {
            IncomingURLCenter.shared.submit(context.url, source: "connect")
        }

        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = NoxSceneDelegate.self
        return configuration
    }

    /// 兼容不使用 scene 的少数调用路径。
    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        IncomingURLCenter.shared.submit(url, source: "delegate")
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        IncomingURLCenter.shared.sceneDidBecomeActive()
    }
}

@MainActor
final class NoxSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        LogStore.shared.info("scene connect · \(connectionOptions.urlContexts.count) url(s)")
        for context in connectionOptions.urlContexts {
            IncomingURLCenter.shared.submit(context.url, source: "scene")
        }

        let hosting = UIHostingController(rootView: NoxRootView())
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        LogStore.shared.info("scene open · \(URLContexts.count) url(s)")
        for context in URLContexts {
            IncomingURLCenter.shared.submit(context.url, source: "scene-open")
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        IncomingURLCenter.shared.sceneDidBecomeActive()
    }
}

/// 根视图：观察语言变化，让 `.locale`（日期 / 数字格式）跟着刷新。
struct NoxRootView: View {
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        ContentView()
            .environment(\.locale, localization.locale)
    }
}
