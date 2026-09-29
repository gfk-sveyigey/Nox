import SwiftUI

@main
struct NoxApp: App {
    /// 观察语言变化，切换后立即刷新 `.locale`（日期/数字格式）
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, localization.locale)
                // 语言切换后强制重建整棵视图树。
                // 否则只有观察了 LocalizationManager 的设置页会刷新，
                // Tab 标题、导航栏标题、各页按钮仍停留在旧语言。
                .id(localization.language)
        }
    }
}