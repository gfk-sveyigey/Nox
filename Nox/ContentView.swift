import SwiftUI
import NoxCore
import NoxDownload
import NoxState

struct ContentView: View {
    @StateObject private var appState: AppState
    @StateObject private var downloadManager: DownloadManager
    @StateObject private var pluginImport = PluginImportCoordinator()
    /// 观察语言变化，让底部 Tab 标题跟着刷新。
    /// 不要再给 `SettingsView` 套 `.id(language)`：那会重建整个 Form，
    /// 把用户正在浏览的设置列表弹回顶部。
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var selectedTab = 0
    @State private var browserURL: URL?
    @State private var didLogSession = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        _downloadManager = StateObject(wrappedValue: DownloadManager(store: state))
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
        .environmentObject(pluginImport)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 浅色 / 深色 / 跟随系统
        .preferredColorScheme(appState.appearanceMode.colorScheme)
        .onAppear {
            // 冷启动时 `scenePhase` 的 onChange 不一定触发，这里补一次前台处理，
            // 让「启动即常驻」模式在首次进入界面时就能拉起保活。
            downloadManager.handleScenePhase(isActive: scenePhase == .active)
            guard !didLogSession else { return }
            didLogSession = true
            LogStore.shared.recordSessionStart()
        }
        // 回到前台：重置速度采样（后台期间定时器不触发），并让后台保活自愈。
        .onChange(of: scenePhase) { _, phase in
            downloadManager.handleScenePhase(isActive: phase == .active)
        }
        // 统一处理外部入口：
        // - nox://open?url=... 交给内置浏览器直接打开
        // - 文件 URL 继续交给插件导入
        .onOpenURL { url in
            if IncomingLink.isPluginImport(url) {
                if let data = IncomingLink.pluginData(from: url) {
                    pluginImport.importSharedPlugin(data)
                } else {
                    pluginImport.reportSharedPluginFailure()
                }
            } else if let webURL = IncomingLink.webURL(from: url) {
                selectedTab = 0
                browserURL = webURL
            } else {
                pluginImport.handleOpenURL(url)
            }
        }
        .alert(item: $pluginImport.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(L("确定")))
            )
        }
    }
}
