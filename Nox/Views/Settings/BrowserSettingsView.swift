import SwiftUI
import NoxCore
import NoxState

struct BrowserSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("请求桌面版网站"), isOn: $appState.browserDesktopMode)
                    .onChange(of: appState.browserDesktopMode) { _, _ in appState.persist() }
            }

            Section {
                NavigationLink {
                    CookiesView()
                } label: {
                    Text(L("Cookie 管理"))
                }
            }
        }
        .navigationTitle(L("浏览设置"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
