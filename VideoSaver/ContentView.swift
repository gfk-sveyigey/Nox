import SwiftUI

struct ContentView: View {
    @StateObject private var appState: AppState

    init() {
        _appState = StateObject(wrappedValue: AppState())
    }

    var body: some View {
        TabView {
            VideoBrowserView(appState: appState)
                .tabItem { Label("浏览", systemImage: "safari") }
            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            HistoryView()
                .tabItem { Label("历史", systemImage: "clock") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .environmentObject(appState)
    }
}
