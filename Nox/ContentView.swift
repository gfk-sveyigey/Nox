import SwiftUI
import UIKit
import NoxCore
import NoxDownload
import NoxState

struct ContentView: View {
    @StateObject private var appState: AppState
    @StateObject private var downloadManager: DownloadManager
    @StateObject private var pluginImport = PluginImportCoordinator()
    @ObservedObject private var incomingURL = IncomingURLCenter.shared
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
            // 冷启动时 document open 可能早于视图安装，这里补一次消费。
            // 延后一个 runloop，确保 alert 等呈现上下文已经装好。
            if let url = incomingURL.pendingURL {
                incomingURL.consume(url)
                DispatchQueue.main.async {
                    handleIncomingURL(url)
                }
            }

            // 有些系统版本把「拷贝到 Nox」的文件放进 Documents/Inbox
            // 却不回调 URL，这里延后扫一次兜底。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                pluginImport.importPendingInboxPluginsIfNeeded()
            }

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

            if phase == .active {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    pluginImport.importPendingInboxPluginsIfNeeded()
                }
            }
        }
        // 统一处理外部入口：
        // - nox://open?url=... 交给内置浏览器直接打开
        // - nox://import-plugin?data=... 导入分享的插件
        // - 文件 URL 继续交给插件导入
        .onOpenURL { url in
            IncomingURLCenter.shared.submit(url)
        }
        .onChange(of: incomingURL.pendingURL) { _, url in
            guard let url else { return }
            handleIncomingURL(url)
            incomingURL.consume(url)
        }
        .alert(item: $pluginImport.prompt) { prompt in
            switch prompt {
            case .notice(let notice):
                return Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text(L("确定")))
                )
            case .confirmation(let confirmation):
                return Alert(
                    title: Text(L("插件已存在")),
                    message: Text(confirmation.message),
                    primaryButton: .default(Text(L("确认导入"))) {
                        pluginImport.confirmImport(confirmation)
                    },
                    secondaryButton: .cancel(Text(L("取消"))) {
                        pluginImport.cancelImport(confirmation)
                    }
                )
            }
        }
    }

    @MainActor
    private func handleIncomingURL(_ url: URL) {
        if IncomingLink.isPluginImport(url) {
            LogStore.shared.info("handle incoming: shared plugin")
            if let data = IncomingLink.pluginData(from: url) {
                pluginImport.importSharedPlugin(data)
            } else {
                LogStore.shared.error("shared plugin url decode failed")
                pluginImport.reportSharedPluginFailure()
            }
        } else if let webURL = IncomingLink.webURL(from: url) {
            LogStore.shared.info("handle incoming: web url")
            selectedTab = 0
            browserURL = webURL
        } else {
            LogStore.shared.info("handle incoming: file")
            pluginImport.handleOpenURL(url)
        }
    }

}
