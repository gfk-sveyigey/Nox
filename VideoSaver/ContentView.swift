import SwiftUI

struct ContentView: View {
    @StateObject private var appState: AppState
    @State private var selectedTab = 0
    @State private var browserURL: URL?

    init() {
        _appState = StateObject(wrappedValue: AppState())
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            VideoBrowserView(appState: appState, requestedURL: $browserURL)
                .tabItem { Label("浏览", systemImage: "safari") }
                .tag(0)

            DownloadsView(appState: appState)
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .tag(1)

            HistoryView { url in
                browserURL = url
                selectedTab = 0
            }
            .tabItem { Label("历史", systemImage: "clock") }
            .tag(2)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .environmentObject(appState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
