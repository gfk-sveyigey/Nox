import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser


struct VideoBrowserView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var localization = LocalizationManager.shared

    @StateObject var parser: VideoParser
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var sniffer = SnifferBridge.shared
    @ObservedObject var registry = VideoSiteParserRegistry.shared

    @Binding var requestedURL: URL?

    @State var address = ""
    @State var parsedVideo: ParsedVideo?
    @State var isParsing = false
    @State var errorMessage: String?
    /// 解析面板内的错误（与地址栏的 `errorMessage` 分开，避免弹窗抢在面板之上）
    @State var parseError: String?
    @State var showParseSheet = false
    @State var showSniffer = false
    @State var pendingRequest: DownloadRequest?
    @State var isFilenameDialogPresented = false
    /// 只存**不含扩展名**的主名 —— 扩展名固定，不让用户改
    @State var filenameInput = ""
    /// 页面向下滚动时收起地址栏（悬浮窗保持不变）
    @State var isScrolledDown = false
    /// 地址栏加载进度条的进度（0…1）与可见 / 呼吸状态（见 `loadProgressBar`）
    @State var progressFraction: Double = 0
    @State var isProgressVisible = false
    @State var isProgressPulsing = false
    /// 进度条是否是「不确定进度」（同文档换页拿不到进度，用固定一段 + 呼吸表达「在动」）
    @State var isProgressIndeterminate = false
    /// 是否显示原生「首页」（尚未打开任何页面，或用户点了主页按钮）
    @State var showingHome = true
    @FocusState var addressFocused: Bool

    /// 地址栏展开 / 收起时的高度
    let controlHeight: CGFloat = 40
    let collapsedControlHeight: CGFloat = 30

    /// 待确认文件名的下载请求。用户点「保存」前的全部信息先攒在这里，
    /// 这样嗅探 / 解析两条路径都能复用同一个弹窗。
    struct DownloadRequest: Identifiable {
        let id = UUID()
        let title: String
        let variant: VideoVariant
        let referer: URL?
        let cookieHeader: String?
        /// 固定的扩展名（不含点）。用户无法修改
        let fileExtension: String
        /// 完整默认文件名（含扩展名），「使用默认文件名」时直接用它
        let defaultFilename: String
    }

    init(appState: AppState, downloads: DownloadManager, requestedURL: Binding<URL?>) {
        _parser = StateObject(wrappedValue: VideoParser(sites: appState))
        _downloads = ObservedObject(wrappedValue: downloads)
        _requestedURL = requestedURL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressToolbar

                // 用 ZStack 而不是 .overlay：让徽标与 WebView 处于同一层级的显式上下关系，
                // 命中测试时徽标在上；`.overlay` 盖在 UIViewRepresentable 之上
                // 有时会被 WKWebView 的图层抢先，导致点击穿透。
                ZStack(alignment: .bottomTrailing) {
                    // 下拉刷新、边缘滑动前进/后退都在 WebView 内部处理
                    WebViewContainer(webView: parser.browserWebView) { offset in
                        updateCollapsedState(for: offset)
                    }
                    .background(Color(.systemBackground))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // 原生首页：盖在 WebView 上，不往网页里塞占位页。
                    // 既让深色模式下「还没打开网页」时不再是白底，也是「主页」入口。
                    if showingHome {
                        homeScreen
                            .transition(.opacity)
                    }

                    if !showingHome {
                        webStateOverlay

                        VStack(alignment: .trailing, spacing: 10) {
                            if isParseBadgeVisible {
                                parseBadge
                                    .transition(.opacity)
                            }

                            if isSnifferBadgeVisible {
                                snifferBadge
                                    .transition(.opacity)
                            }
                        }
                        .padding(16)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: isParseBadgeVisible)
            .animation(.easeInOut(duration: 0.2), value: isSnifferBadgeVisible)
            .animation(.easeInOut(duration: 0.2), value: showingHome)
            // 浏览页没有导航栏内容。保留空 NavigationStack 的导航栏会在地址栏上方
            // 多出一条空白，直接隐藏；顶部安全区仍由系统保留。
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                loadRequestedURLIfNeeded()
                parser.refreshSiteRules()
                // 切走再切回来时 `isLoading` 不一定有变化，这里按当前状态补一次。
                updateProgressAppearance(isLoading: showsLoadingIndicator)
            }
            .onChange(of: requestedURL) { _, _ in
                loadRequestedURLIfNeeded()
            }
            // 地址栏跟随 WebView 的实际地址：页面内点链接、重定向、后退/前进都会更新。
            .onChange(of: parser.currentURL) { _, newValue in
                syncAddress(with: newValue)
            }
            // 导入 / 删除插件或调整匹配顺序后，立即刷新当前页面能否解析。
            // 监听 revision 而不是只比较 id 列表：同 id 插件原位更新时
            // id 列表不变，但匹配规则可能已经变了。
            .onChange(of: registry.revision) { _, _ in
                parser.refreshSiteRules()
            }
            // 在设置里开关站点后，无需等下一次导航再更新解析入口。
            .onChange(of: appState.siteAvailabilityRevision) { _, _ in
                parser.refreshSiteRules()
            }
            // 加载提示：开 / 关看合并后的状态（真实导航 or 同文档换页），
            // 具体进度按 estimatedProgress 走。
            .onChange(of: showsLoadingIndicator) { _, loading in
                updateProgressAppearance(isLoading: loading)
            }
            .onChange(of: parser.loadProgress) { _, value in
                guard parser.isLoading else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    progressFraction = max(progressFraction, min(max(value, 0), 1))
                }
            }
            // 「同文档换页的提示还没结束，又发起了真实导航」时，把形态切回确定进度，
            // 否则进度条会一直停在那个固定宽度上（合计状态没变，上面那个 onChange 不会触发）。
            .onChange(of: parser.isLoading) { _, loading in
                guard loading, showsLoadingIndicator else { return }
                isProgressIndeterminate = false
            }
            .alert(
                L("解析失败"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(L("确定"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(
                L("保存文件"),
                isPresented: $isFilenameDialogPresented,
                presenting: pendingRequest
            ) { request in
                TextField(L("文件名"), text: $filenameInput)

                Button(L("使用默认文件名")) {
                    commit(request, useCustom: false)
                }

                Button(L("保存")) {
                    commit(request, useCustom: true)
                }

                Button(L("取消"), role: .cancel) {
                    pendingRequest = nil
                }
            } message: { request in
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: L("扩展名固定为 .%@，不可修改"), request.fileExtension))
                    Text(String(format: L("默认文件名：%@"), request.defaultFilename))
                }
            }
            .onChange(of: isFilenameDialogPresented) { _, presented in
                // 任何非「保存」的关闭路径（点空白、下拉收起、系统收起）都视为取消：
                // 只丢弃待办请求，不会入队下载。
                if !presented { pendingRequest = nil }
            }

        }
    }
}
