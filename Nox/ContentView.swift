import SwiftUI
import UIKit
import QuartzCore
import NoxCore
import NoxDownload
import NoxState

struct ContentView: View {
    @ObservedObject private var appState: AppState
    @ObservedObject private var downloadManager: DownloadManager
    @StateObject private var pluginImport = PluginImportCoordinator.shared
    @ObservedObject private var incomingURL = IncomingURLCenter.shared
    /// 观察语言变化，让底部 Tab 标题跟着刷新。
    /// 不要再给 `SettingsView` 套 `.id(language)`：那会重建整个 Form，
    /// 把用户正在浏览的设置列表弹回顶部。
    @ObservedObject private var localization = LocalizationManager.shared
    /// 用 ObservableObject 包住选中项：TabView 在重复点击当前标签时，
    /// 会把同一个值再写回绑定，借此可以拿到系统的「再次点击」事件。
    @StateObject private var tabSelection = TabSelectionState()
    @State private var browserURL: URL?
    @State private var didLogSession = false
    @State private var startupFinished = false
    @State private var didPrepareStartup = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let services = AppServices.shared
        _appState = ObservedObject(wrappedValue: services.appState)
        _downloadManager = ObservedObject(wrappedValue: services.downloadManager)
    }

    var body: some View {
        TabView(selection: $tabSelection.selection) {
            VideoBrowserView(
                appState: appState,
                downloads: downloadManager,
                requestedURL: $browserURL,
                scrollToTopToken: tabSelection.browseDoubleTapCount
            )
                .tabItem { Label(L("浏览"), systemImage: "safari") }
                .tag(0)

            DownloadsView(
                appState: appState,
                manager: downloadManager,
                scrollToTopToken: tabSelection.downloadsDoubleTapCount
            )
                .tabItem { Label(L("下载"), systemImage: "arrow.down.circle") }
                .tag(1)

            HistoryView(
                scrollToTopToken: tabSelection.historyDoubleTapCount
            ) { url in
                browserURL = url
                tabSelection.selection = 0
            }
                .tabItem { Label(L("历史"), systemImage: "clock") }
                .tag(2)

            SettingsView(
                manager: downloadManager,
                scrollToTopToken: tabSelection.settingsDoubleTapCount
            )
                .tabItem { Label(L("设置"), systemImage: "gearshape") }
                .tag(3)
        }
        .environmentObject(appState)
        .environmentObject(pluginImport)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if !startupFinished {
                StartupView()
                    .zIndex(100)
            }
        }
        // 浅色 / 深色 / 跟随系统
        .preferredColorScheme(appState.appearanceMode.colorScheme)
        .onAppear {
            prepareStartupIfNeeded()

            // 视图与 .alert 已经挂好，可以接收冷启动期间排队的文件打开了。
            incomingURL.markUIReady()
            // 冷启动时 scene 可能先于视图进入 active；再补一次，避免文件一直排队。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                incomingURL.sceneDidBecomeActive()
            }

            // 冷启动时 document open 可能早于视图安装，这里补一次消费。
            // 延后一个 runloop，确保 alert 等呈现上下文已经装好。
            if let url = incomingURL.pendingURL {
                incomingURL.consume(url)
                DispatchQueue.main.async {
                    handleIncomingURL(url)
                }
            }

            LogStore.shared.info(
                "shared inbox · \(SharedPluginInbox.isAvailable ? "available" : "unavailable")"
            )

            // 有些系统版本把「拷贝到 Nox」的文件放进 Documents/Inbox
            // 却不回调 URL，这里多扫几次，覆盖系统延迟写入的情况。
            for delay in [0.6, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    pluginImport.importPendingInboxPluginsIfNeeded()
                }
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
                incomingURL.sceneDidBecomeActive()
                for delay in [0.6, 1.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        pluginImport.importPendingInboxPluginsIfNeeded()
                    }
                }
            }
        }
        // 调整「同时下载任务数」后立即重排队列，确保活跃任务不超过新上限。
        .onChange(of: appState.maxConcurrentDownloads) { _, _ in
            downloadManager.reconcileQueue()
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
                    dismissButton: .default(Text(L("确定"))) {
                        pluginImport.dismissNotice(notice)
                    }
                )
            case .confirmation(let confirmation):
                return Alert(
                    title: Text(L("插件已存在")),
                    message: Text(confirmation.message),
                    primaryButton: .default(Text(L("替换"))) {
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
    private func prepareStartupIfNeeded() {
        guard !didPrepareStartup else { return }
        didPrepareStartup = true

        // 预建画中画基础设施；失败也不会影响启动。
        downloadManager.prepareForLaunch()

        // 留一小段准备时间，避免覆盖层闪一下就消失。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            startupFinished = true
        }
    }

    @MainActor
    private func handleIncomingURL(_ url: URL) {
        if IncomingLink.isPluginImport(url) {
            LogStore.shared.info("handle incoming: shared plugin")
            if let data = IncomingLink.pluginData(from: url) {
                pluginImport.importSharedPlugin(data)
            } else if IncomingLink.hasInlinePluginData(url) {
                LogStore.shared.error("shared plugin url decode failed")
                pluginImport.reportSharedPluginFailure()
            } else {
                // 新版分享扩展只回传短链接，插件本体在 App Group 收件箱里。
                pluginImport.importPendingSharedPlugins()
            }
        } else if IncomingLink.isDownloads(url) {
            LogStore.shared.info("handle incoming: downloads")
            tabSelection.selection = 1
        } else if let webURL = IncomingLink.webURL(from: url) {
            LogStore.shared.info("handle incoming: web url")
            tabSelection.selection = 0
            browserURL = webURL
        } else {
            LogStore.shared.info("handle incoming: file")
            pluginImport.handleOpenURL(url)
        }
    }

}

/// `TabView` 的 selection 包装，用重复写入的选中项识别双击当前标签。
final class TabSelectionState: ObservableObject {
    /// 两下之间允许的最长间隔。
    static let doubleTapInterval: TimeInterval = 0.45

    @Published var selection: Int = 0 {
        didSet {
            guard oldValue == selection else {
                // 正常的标签切换不是「再次点击」，并清掉切换前残留的候选，
                // 避免换到别的标签再回来后被拼成一次双击。
                resetDoubleTap()
                return
            }

            // 重复点击当前标签才会走到这里。
            handleTabReselect(selection)
        }
    }

    /// 双击「浏览」的次数；浏览页观察它并滚回顶部。
    @Published private(set) var browseDoubleTapCount = 0
    @Published private(set) var downloadsDoubleTapCount = 0
    @Published private(set) var historyDoubleTapCount = 0
    @Published private(set) var settingsDoubleTapCount = 0

    private var lastReselectAt = -Double.infinity

    private func handleTabReselect(_ tab: Int) {
        let now = CACurrentMediaTime()

        if now - lastReselectAt <= Self.doubleTapInterval {
            resetDoubleTap()
            switch tab {
            case 0: browseDoubleTapCount += 1
            case 1: downloadsDoubleTapCount += 1
            case 2: historyDoubleTapCount += 1
            case 3: settingsDoubleTapCount += 1
            default: break
            }
        } else {
            lastReselectAt = now
        }
    }

    private func resetDoubleTap() {
        lastReselectAt = -Double.infinity
    }
}
