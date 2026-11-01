import SwiftUI
import NoxCore

@main
struct NoxApp: App {
    /// 兜住 SwiftUI `.onOpenURL` 收不到的 document open（其他 App 用 Nox 打开文件）。
    @UIApplicationDelegateAdaptor(NoxAppDelegate.self) private var appDelegate
    /// 观察语言变化，刷新 `.locale`（日期/数字格式）
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, localization.locale)
        }
    }
}