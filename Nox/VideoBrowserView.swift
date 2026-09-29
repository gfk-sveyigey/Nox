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
    @State private var showVariants = false
    @State private var showSniffer = false
    @State private var pendingRequest: DownloadRequest?
    @State private var isFilenameDialogPresented = false
    /// 只存**不含扩展名**的主名 —— 扩展名固定，不让用户改
    @State private var filenameInput = ""
    @FocusState private var addressFocused: Bool

    /// 统一控件高度，解决按钮与输入框高低不齐
    private let controlHeight: CGFloat = 40

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
                browserToolbar

                // 用 ZStack 而不是 .overlay：让徽标与 WebView 处于同一层级的显式上下关系，
                // 命中测试时徽标在上；`.overlay` 盖在 UIViewRepresentable 之上
                // 有时会被 WKWebView 的图层抢先，导致点击穿透。
                ZStack(alignment: .bottomTrailing) {
                    // 下拉刷新、边缘滑动前进/后退都在 WebView 内部处理
                    WebViewContainer(webView: parser.browserWebView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isSnifferBadgeVisible {
                        snifferBadge
                            .padding(16)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: isSnifferBadgeVisible)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadRequestedURLIfNeeded()
            }
            .onChange(of: requestedURL) { _, _ in
                loadRequestedURLIfNeeded()
            }
            .sheet(isPresented: $showVariants) {
                variantSheet
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

    // MARK: - 顶部工具栏（单行，两个控件等高）

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            addressBar

            Button {
                Task {
                    await parse()
                }
            } label: {
                Group {
                    if isParsing {
                        ProgressView()
                    } else {
                        Label(L("解析视频"), systemImage: "arrow.down.circle")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                    }
                }
                .frame(height: controlHeight)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            // cornerRadius 传 nil ⇒ 胶囊形，两端是半圆
            .browserGlassBar(cornerRadius: nil)
            .opacity(parser.canParseCurrentPage && !isParsing ? 1 : 0.45)
            .disabled(!parser.canParseCurrentPage || isParsing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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

            Button {
                openAddress()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("打开"))
        }
        .padding(.horizontal, 12)
        .frame(height: controlHeight)
        .browserGlassBar()
    }

    // MARK: - 嗅探面板入口

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

    /// 悬浮胶囊：显示当前已嗅探到的资源数。
    ///
    /// 用 `contentShape(Capsule())` 把命中区域收敛到胶囊本身，
    /// 否则外层留白会落到 WebView 上（表现为「点按钮顺带点了页面」）。
    /// `.sheet` 挂在徽标上而不是外层 `VStack`：后者已挂了 `variantSheet`，
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

    // MARK: - 清晰度选择

    private var variantSheet: some View {
        NavigationStack {
            List(parsedVideo?.variants ?? []) { variant in
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
            .navigationTitle(Text(parsedVideo?.title ?? L("选择清晰度")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("关闭")) {
                        showVariants = false
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
        guard parser.canParseCurrentPage else { return }

        addressFocused = false

        isParsing = true
        defer { isParsing = false }

        do {
            parsedVideo = try await parser.parseCurrentPage()

            if let video = parsedVideo,
               let variant = preferredVariant(
                    video.variants,
                    preference: appState.preferredQuality
               ) {
                await download(variant)
            } else {
                showVariants = true
            }
        } catch {
            errorMessage = error.localizedDescription
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
        showVariants = false
        showSniffer = false

        Task {
            let cookieHeader = await parser.cookieHeaderForCurrentPage()

            let suggested = downloads.suggestedFilename(
                title: title,
                quality: variant.quality,
                format: variant.format
            )

            // 等 sheet 退场动画走完再弹 alert：动画期间同步 present 会被系统静默丢弃
            try? await Task.sleep(nanoseconds: 350_000_000)

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

    func makeCoordinator() -> Coordinator {
        Coordinator(webView: webView)
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

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator {
        private weak var webView: WKWebView?
        private var observation: NSKeyValueObservation?

        init(webView: WKWebView) {
            self.webView = webView

            // 加载结束后收起刷新指示器，否则会一直转
            observation = webView.observe(\.isLoading, options: [.new]) { webView, _ in
                guard !webView.isLoading else { return }
                webView.scrollView.refreshControl?.endRefreshing()
            }
        }

        @objc func refresh() {
            webView?.reload()
        }
    }
}