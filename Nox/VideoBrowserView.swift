import SwiftUI
import WebKit

struct VideoBrowserView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared

    @StateObject private var parser: VideoParser
    @ObservedObject private var downloads: DownloadManager
    @ObservedObject private var sniffer = SnifferBridge.shared

    @Binding private var requestedURL: URL?

    @State private var address = ""
    @State private var parsedVideo: ParsedVideo?
    @State private var isParsing = false
    @State private var errorMessage: String?
    /// 解析面板内的错误（与地址栏的 `errorMessage` 分开，避免弹窗抢在面板之上）
    @State private var parseError: String?
    @State private var showParseSheet = false
    @State private var showSniffer = false
    @State private var pendingRequest: DownloadRequest?
    @State private var isFilenameDialogPresented = false
    /// 只存**不含扩展名**的主名 —— 扩展名固定，不让用户改
    @State private var filenameInput = ""
    /// 页面向下滚动时收起地址栏（悬浮窗保持不变）
    @State private var isScrolledDown = false
    @FocusState private var addressFocused: Bool

    /// 地址栏展开 / 收起时的高度
    private let controlHeight: CGFloat = 40
    private let collapsedControlHeight: CGFloat = 30

    /// 待确认文件名的下载请求。用户点「保存」前的全部信息先攒在这里，
    /// 这样嗅探 / 解析两条路径都能复用同一个弹窗。
    private struct DownloadRequest: Identifiable {
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
        _parser = StateObject(wrappedValue: VideoParser(appState: appState))
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: isParseBadgeVisible)
            .animation(.easeInOut(duration: 0.2), value: isSnifferBadgeVisible)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadRequestedURLIfNeeded()
            }
            .onChange(of: requestedURL) { _, _ in
                loadRequestedURLIfNeeded()
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

    // MARK: - 顶部地址栏

    /// 地址栏：胶囊形，只保留输入框与「清空」。
    /// 页面向下滚动时高度收缩，回到顶部再展开。
    private var addressToolbar: some View {
        addressBar
            .padding(.horizontal, 10)
            .padding(.vertical, isScrolledDown ? 3 : 8)
            .animation(.easeInOut(duration: 0.2), value: isScrolledDown)
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            TextField(L("输入网页地址"), text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    openAddress()
                }

            if !address.isEmpty {
                Button {
                    address = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("清空地址栏"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: isScrolledDown ? collapsedControlHeight : controlHeight)
        .browserGlassBar(cornerRadius: nil)
    }

    private func updateCollapsedState(for offset: CGFloat) {
        let collapsed = offset > 24
        guard collapsed != isScrolledDown else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            isScrolledDown = collapsed
        }
    }

    // MARK: - 悬浮入口（解析 / 嗅探）

    /// 「通用嗅探」在设置页是否开启
    private var isSnifferEnabled: Bool {
        appState.isSiteEnabled(GenericSnifferParser.siteIdentifier)
    }

    /// 只有当前页面**确实靠通用嗅探兜底**时才显示入口。
    ///
    /// 页面被具名站点解析器（如 Pornhub）命中时，「解析视频」已经能给出更准确的
    /// 清晰度清单，再摆一个嗅探入口只会得到重复且标注更差的结果。
    /// 反过来，把某个站点的开关关掉，该站点页面就会自动回落到嗅探 —— 语义自洽。
    private var isSnifferBadgeVisible: Bool {
        isSnifferEnabled
            && parser.currentParserIdentifier == GenericSnifferParser.siteIdentifier
            && !sniffer.items.isEmpty
    }

    /// 页面可解析时显示。
    private var isParseBadgeVisible: Bool {
        parser.canParseCurrentPage
    }

    /// 「解析视频」悬浮胶囊：与嗅探入口同样的样式，点击弹出半屏面板。
    private var parseBadge: some View {
        Button {
            parsedVideo = nil
            parseError = nil
            showParseSheet = true
            Task { await parse() }
        } label: {
            HStack(spacing: 6) {
                if isParsing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }

                Text(L("解析视频"))
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .browserGlassBar(cornerRadius: nil)
        .zIndex(1)
        .accessibilityLabel(L("解析视频"))
        .sheet(isPresented: $showParseSheet) {
            parseSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// 悬浮胶囊：显示当前已嗅探到的资源数。
    ///
    /// 用 `contentShape(Capsule())` 把命中区域收敛到胶囊本身，
    /// 否则外层留白会落到 WebView 上（表现为「点按钮顺带点了页面」）。
    /// `.sheet` 挂在徽标上而不是外层 `VStack`：后者已挂了 `parseSheet`，
    /// 同一视图叠两个 `.sheet` 会互相干扰。
    private var snifferBadge: some View {
        Button {
            showSniffer = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")

                Text(String(sniffer.items.count))
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .browserGlassBar(cornerRadius: nil)
        .zIndex(1)
        .accessibilityLabel(L("已嗅探"))
        .sheet(isPresented: $showSniffer) {
            SnifferSheet(
                onRescan: {
                    await parser.rescanPage()
                },
                onDownload: { item in
                    download(item)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - 解析面板（半屏）

    private var parseSheet: some View {
        NavigationStack {
            Group {
                if isParsing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L("正在解析…"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let video = parsedVideo, !video.variants.isEmpty {
                    List(video.variants) { variant in
                        Button {
                            Task {
                                await download(variant)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(variant.displayName)
                                    Text(variant.url.host ?? L("媒体"))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: "arrow.down.circle.fill")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        L("解析失败"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(parseError ?? L("没有找到可下载的视频清晰度。"))
                    )
                }
            }
            .navigationTitle(Text(parsedVideo?.title ?? L("解析视频")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("关闭")) {
                        showParseSheet = false
                    }
                }
            }
        }
    }

    // MARK: - 行为

    private func loadRequestedURLIfNeeded() {
        guard let url = requestedURL else { return }

        requestedURL = nil
        address = url.absoluteString
        parser.load(url)
    }

    private func openAddress() {
        // 点击打开后收起键盘
        addressFocused = false

        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if !text.contains("://") {
            text = "https://" + text
        }

        guard let url = URL(string: text), url.scheme == "https" else {
            errorMessage = L("请输入 HTTPS 地址。")
            return
        }

        address = url.absoluteString
        parser.load(url)
    }

    private func parse() async {
        guard parser.canParseCurrentPage, !isParsing else { return }

        addressFocused = false

        isParsing = true
        parseError = nil
        defer { isParsing = false }

        do {
            let video = try await parser.parseCurrentPage()
            parsedVideo = video

            // 设置里选了明确清晰度就直接开下；否则留在面板里让用户挑。
            if let variant = preferredVariant(
                video.variants,
                preference: appState.preferredQuality
            ) {
                await download(variant)
            }
        } catch {
            parsedVideo = nil
            parseError = error.localizedDescription
        }
    }

    private func preferredVariant(
        _ variants: [VideoVariant],
        preference: PreferredQuality
    ) -> VideoVariant? {
        switch preference {
        case .ask:
            return nil
        case .best:
            return variants.max {
                qualityNumber($0.quality) < qualityNumber($1.quality)
            } ?? variants.first
        case .p1080, .p720, .p480, .p360:
            if let exact = variants.first(where: {
                qualityNumber($0.quality) == preference.qualityNumber
            }) {
                return exact
            }
            // 找不到目标清晰度时退回最高可用
            return variants.max {
                qualityNumber($0.quality) < qualityNumber($1.quality)
            } ?? variants.first
        }
    }

    private func qualityNumber(_ quality: String) -> Int {
        Int(quality.filter(\.isNumber)) ?? 0
    }

    /// 「解析视频」路径。历史已由 `parseCurrentPage()` 记过，这里不重复记。
    private func download(_ variant: VideoVariant) async {
        guard let parsedVideo else { return }
        prepareDownload(title: parsedVideo.title, variant: variant, referer: parsedVideo.pageURL)
    }

    /// 嗅探面板路径。
    ///
    /// - 历史记的是**页面**地址与页面标题，而不是媒体地址：
    ///   历史页的「跳转网页」要能回到原页面，且同一页面上的多条资源不会各占一条记录。
    /// - Referer 用 WebView 当前地址。
    private func download(_ item: SnifferBridge.Item) {
        showSniffer = false

        appState.addHistory(
            title: parser.currentPageTitle ?? item.displayTitle,
            url: parser.currentPageURL ?? item.url
        )

        prepareDownload(
            title: item.displayTitle,
            variant: VideoVariant(
                quality: item.qualityLabel,
                format: item.format,
                url: item.url
            ),
            referer: parser.currentPageURL
        )
    }

    /// 统一的入队前准备：收起所有 sheet、取 Cookie、生成默认文件名、弹「选择文件名」。
    private func prepareDownload(title: String, variant: VideoVariant, referer: URL?) {
        showParseSheet = false
        showSniffer = false

        Task {
            let cookieHeader = await parser.cookieHeaderForCurrentPage()

            let suggested = downloads.suggestedFilename(
                title: title,
                quality: variant.quality,
                format: variant.format
            )

            // 等 sheet 退场动画走完再弹 alert：动画期间同步 present 会被系统静默丢弃
            try? await Task.sleep(nanoseconds: 450_000_000)

            let suggestedURL = URL(fileURLWithPath: suggested)
            let fileExtension = suggestedURL.pathExtension

            // 输入框只放主名，扩展名单独固定，用户看不到也改不了
            filenameInput = suggestedURL.deletingPathExtension().lastPathComponent

            pendingRequest = DownloadRequest(
                title: title,
                variant: variant,
                referer: referer,
                cookieHeader: cookieHeader,
                fileExtension: fileExtension,
                defaultFilename: suggested
            )

            isFilenameDialogPresented = true
        }
    }

    private func commit(_ request: DownloadRequest, useCustom: Bool) {
        var filename = request.defaultFilename

        if useCustom {
            // 用户只能改主名。就算他手动敲了后缀，也按固定扩展名收口 ——
            // 否则会出现「选了 .mp4 却存成 .mp4.txt」这类坏文件。
            let stem = Self.stem(
                from: filenameInput,
                stripping: request.fileExtension
            )

            if !stem.isEmpty {
                filename = "\(stem).\(request.fileExtension)"
            }
        }

        downloads.enqueue(
            title: request.title,
            variant: request.variant,
            referer: request.referer,
            cookieHeader: request.cookieHeader,
            filename: filename
        )

        isFilenameDialogPresented = false
    }

    /// 只剥掉「与固定扩展名完全一致」的尾缀。
    /// 不能按 `pathExtension` 通用剥离 —— 像 `S01.E02` 这种主名里的点会被误伤。
    private static func stem(from text: String, stripping fileExtension: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileExtension.isEmpty else { return trimmed }

        let suffix = "." + fileExtension

        if trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            return String(trimmed.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }
}

// MARK: - 玻璃样式

private extension View {
    @ViewBuilder
    func browserGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// 液态玻璃「容器」样式（地址栏、解析按钮）。
    ///
    /// - Parameter cornerRadius: 传具体值得圆角矩形（默认 12）；传 `nil` 得**胶囊形**，两端为半圆。
    @ViewBuilder
    func browserGlassBar(cornerRadius: CGFloat? = 12) -> some View {
        if #available(iOS 26.0, *) {
            if let cornerRadius {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .capsule)
            }
        } else {
            if let cornerRadius {
                self.background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            } else {
                self.background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
}

// MARK: - WKWebView 容器（含下拉刷新）

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    /// 滚动偏移回调：供外层收缩地址栏。
    var onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(webView: webView, onScroll: onScroll)
    }

    func makeUIView(context: Context) -> WKWebView {
        // 下拉刷新（替代原来的「刷新」按钮）
        if webView.scrollView.refreshControl == nil {
            let control = UIRefreshControl()
            control.addTarget(
                context.coordinator,
                action: #selector(Coordinator.refresh),
                for: .valueChanged
            )
            webView.scrollView.refreshControl = control
        }

        context.coordinator.startObservingOffset()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    final class Coordinator {
        private weak var webView: WKWebView?
        private var observation: NSKeyValueObservation?
        private var offsetObservation: NSKeyValueObservation?
        var onScroll: (CGFloat) -> Void

        init(webView: WKWebView, onScroll: @escaping (CGFloat) -> Void) {
            self.webView = webView
            self.onScroll = onScroll

            // 加载结束后收起刷新指示器，否则会一直转
            observation = webView.observe(\.isLoading, options: [.new]) { webView, _ in
                guard !webView.isLoading else { return }
                webView.scrollView.refreshControl?.endRefreshing()
            }
        }

        func startObservingOffset() {
            guard offsetObservation == nil, let webView else { return }

            // contentOffset 的 KVO 回调在主线程投递，直接转给闭包即可（省去每帧派发的开销）
            offsetObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                self?.onScroll(scrollView.contentOffset.y)
            }
        }

        @objc func refresh() {
            webView?.reload()
        }
    }
}
