import SwiftUI
import UIKit
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
    @State private var selectedTab = 0
    @State private var browserURL: URL?
    @State private var browserAllowsMinimization = false
    @State private var browserCanParse = false
    @State private var taskFilterHasItems = false
    @State private var parseRequest = UUID()
    @State private var taskMenuRequest = UUID()
    @State private var aboutRequest = UUID()
    @State private var actionNotice: String?
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
        mainTabs
        .modifier(NativeBrowserTabMinimization(enabled: selectedTab == 0 && browserAllowsMinimization))
        .onPreferenceChange(BrowserParseAvailability.self) { browserCanParse = $0 }
        .onPreferenceChange(TaskFilterAvailabilityPreference.self) { taskFilterHasItems = $0 }
        .onPreferenceChange(BrowserMinimizationPreference.self) { browserAllowsMinimization = $0 }
        .alert(L("提示"), isPresented: Binding(get: { actionNotice != nil }, set: { if !$0 { actionNotice = nil } })) {
            Button(L("确定"), role: .cancel) { actionNotice = nil }
        } message: { Text(actionNotice ?? "") }
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

    private func selectTab(_ value: Int) {
        selectedTab = value
    }

    private var contextActionTitle: String {
        selectedTab == 1 ? L("任务总览") : selectedTab == 2 ? L("关于") : L("解析")
    }

    private var contextActionImage: String {
        selectedTab == 1 ? "square.grid.2x2" : selectedTab == 2 ? "info.circle" : "dot.radiowaves.left.and.right"
    }

    private var contextActionEnabled: Bool {
        selectedTab != 1 || taskFilterHasItems
    }

    private func activateContextAction() {
        switch selectedTab {
        case 1:
            guard taskFilterHasItems else {
                actionNotice = L("当前筛选类型没有任务。")
                return
            }
            taskMenuRequest = UUID()
        case 2:
            aboutRequest = UUID()
        default:
            guard browserAllowsMinimization else {
                actionNotice = L("当前页面暂无可解析的内容。")
                return
            }
            guard browserCanParse else {
                actionNotice = L("解析未完成。")
                return
            }
            parseRequest = UUID()
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(get: { selectedTab }, set: { value in
            if value == 3 {
                activateContextAction()
            } else {
                selectTab(value)
            }
        })
    }

    private var browser: some View {
        VideoBrowserView(appState: appState, downloads: downloadManager,
                         requestedURL: $browserURL, parseRequest: parseRequest)
    }

    @ViewBuilder
    private var mainTabs: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: tabSelection) {
                Tab(L("浏览"), systemImage: "safari", value: 0) { browser }
                Tab(L("任务"), systemImage: "arrow.down.circle", value: 1) {
                    DownloadsView(appState: appState, manager: downloadManager, menuRequest: taskMenuRequest)
                }
                Tab(L("设置"), systemImage: "gearshape", value: 2) {
                    SettingsView(manager: downloadManager, aboutRequest: aboutRequest)
                }
                Tab(value: 3, role: .search) { Color.clear } label: {
                        Label(contextActionTitle, systemImage: contextActionImage)
                    }
            }
            .background(ParseTabAvailability(isEnabled: true) { activateContextAction() })
        } else {
            TabView(selection: tabSelection) {
                browser.tabItem { Label(L("浏览"), systemImage: "safari") }.tag(0)
                DownloadsView(appState: appState, manager: downloadManager, menuRequest: taskMenuRequest)
                    .tabItem { Label(L("任务"), systemImage: "arrow.down.circle") }.tag(1)
                SettingsView(manager: downloadManager, aboutRequest: aboutRequest)
                    .tabItem { Label(L("设置"), systemImage: "gearshape") }.tag(2)
                Color.clear
                    .tabItem { Label(contextActionTitle, systemImage: contextActionImage) }
                    .tag(3)
            }
            .background(ParseTabAvailability(isEnabled: true) { activateContextAction() })
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
            selectTab(1)
        } else if let webURL = IncomingLink.webURL(from: url) {
            LogStore.shared.info("handle incoming: web url")
            selectTab(0)
            browserURL = webURL
        } else {
            LogStore.shared.info("handle incoming: file")
            pluginImport.handleOpenURL(url)
        }
    }

}

private struct NativeBrowserTabMinimization: ViewModifier {
    let enabled: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(enabled ? .onScrollDown : .never)
        } else {
            content
        }
    }
}

/// Keep the action tab's native disabled appearance and accessibility state in sync.
private struct ParseTabAvailability: UIViewControllerRepresentable {
    let isEnabled: Bool
    let onParse: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.actionEnabled = isEnabled
        controller.onParse = onParse
        controller.updateItem()
        DispatchQueue.main.async { controller.updateItem() }
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restoreDelegate()
    }
    final class Controller: UIViewController, UITabBarControllerDelegate {
        var actionEnabled = false
        var onParse: (() -> Void)?
        private weak var observedTabs: UITabBarController?
        private weak var originalDelegate: UITabBarControllerDelegate?
        func restoreDelegate() {
            if observedTabs?.delegate === self {
                observedTabs?.delegate = originalDelegate
            }
        }

        // A parse tap is an action, never a tab selection. Reject it before
        // UIKit changes the selected controller or expands the minimized bar.
        func tabBarController(_ tabBarController: UITabBarController,
                              shouldSelect viewController: UIViewController) -> Bool {
            if let controllers = tabBarController.viewControllers,
               controllers.count == 4, controllers[3] === viewController {
                if actionEnabled { onParse?() }
                return false
            }
            return originalDelegate?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateItem()
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updateItem()
        }
        func updateItem() {
            func findTabs(_ controller: UIViewController) -> UITabBarController? {
                if let tabs = controller as? UITabBarController { return tabs }
                for child in controller.children {
                    if let tabs = findTabs(child) { return tabs }
                }
                return nil
            }
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard let tabs = findTabs(root), let items = tabs.tabBar.items else { return }
            if tabs.delegate !== self {
                originalDelegate = tabs.delegate
                observedTabs = tabs
                tabs.delegate = self
            }
            guard items.count == 4 else { return }
            items[3].isEnabled = actionEnabled
            items[3].setTitleTextAttributes([.foregroundColor: UIColor.secondaryLabel], for: .normal)
            items[3].setTitleTextAttributes([.foregroundColor: UIColor.tertiaryLabel], for: .disabled)
        }
    }
}
