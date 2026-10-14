import SwiftUI

struct ContentView: View {
    @StateObject private var appState: AppState
    @StateObject private var downloadManager: DownloadManager
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var selectedTab = 0
    @State private var browserURL: URL?
    @State private var didLogSession = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        _downloadManager = StateObject(wrappedValue: DownloadManager(appState: state))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            VideoBrowserView(appState: appState, downloads: downloadManager, requestedURL: $browserURL)
                .tabItem { Label(L("浏览"), systemImage: "safari") }
                .tag(0)

            DownloadsView(appState: appState, manager: downloadManager)
                .tabItem { Label(L("下载"), systemImage: "arrow.down.circle") }
                .tag(1)

            HistoryView { url in
                browserURL = url
                selectedTab = 0
            }
            .tabItem { Label(L("历史"), systemImage: "clock") }
            .tag(2)

            SettingsView(manager: downloadManager)
                .tabItem { Label(L("设置"), systemImage: "gearshape") }
                .tag(3)
        }
        .environmentObject(appState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 浅色 / 深色 / 跟随系统
        .preferredColorScheme(appState.appearanceMode.colorScheme)
        .onAppear {
            guard !didLogSession else { return }
            didLogSession = true
            LogStore.shared.recordSessionStart()
        }
        // 回到前台：重置速度采样（后台期间定时器不触发），并让后台保活自愈。
        .onChange(of: scenePhase) { _, phase in
            downloadManager.handleScenePhase(isActive: phase == .active)
        }
    }
}