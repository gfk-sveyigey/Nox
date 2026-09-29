import SwiftUI

@main
struct NoxApp: App {
    /// 观察语言变化，刷新 `.locale`（日期/数字格式）
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, localization.locale)
        }
    }
}