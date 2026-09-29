import SwiftUI
import WebKit

struct VideoBrowserView: View {
    @EnvironmentObject private var appState: AppState

    @StateObject private var parser: VideoParser
    @ObservedObject private var downloads: DownloadManager

    @Binding private var requestedURL: URL?

    @State private var address = ""
    @State private var parsedVideo: ParsedVideo?
    @State private var isParsing = false
    @State private var errorMessage: String?
    @State private var showVariants = false
    @FocusState private var addressFocused: Bool

    /// 统一控件高度，解决按钮与输入框高低不齐
    private let controlHeight: CGFloat = 40

    init(appState: AppState, downloads: DownloadManager, requestedURL: Binding<URL?>) {
        _parser = StateObject(wrappedValue: VideoParser(appState: appState))
        _downloads = ObservedObject(wrappedValue: downloads)
        _requestedURL = requestedURL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                browserToolbar

                // 下拉刷新、边缘滑动前进/后退都在 WebView 内部处理
                WebViewContainer(webView: parser.browserWebView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .toolbar {
                // 输入时可随时收起键盘
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        addressFocused = false
                    }
                }
            }
            .alert(
                "解析失败",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
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
                        Label("解析视频", systemImage: "arrow.down.circle")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                    }
                }
                // 与地址栏共用 controlHeight，避免玻璃按钮样式撑高
                .frame(height: controlHeight)
                .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .browserGlassBar()
            .opacity(parser.canParseCurrentPage && !isParsing ? 1 : 0.45)
            .disabled(!parser.canParseCurrentPage || isParsing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            TextField("输入网页地址", text: $address)
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
                .accessibilityLabel("清空地址栏")
            }

            Button {
                openAddress()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开")
        }
        .padding(.horizontal, 12)
        .frame(height: controlHeight)
        .browserGlassBar()
    }

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
                            Text(variant.url.host ?? "media")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "arrow.down.circle.fill")
                    }
                }
            }
            .navigationTitle(Text(parsedVideo?.title ?? String(localized: "选择清晰度")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
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
            errorMessage = String(localized: "请输入 HTTPS 地址。")
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

    private func download(_ variant: VideoVariant) async {
        guard let parsedVideo else { return }

        let cookieHeader = await parser.cookieHeaderForCurrentPage()

        downloads.enqueue(
            title: parsedVideo.title,
            variant: variant,
            referer: parsedVideo.pageURL,
            cookieHeader: cookieHeader
        )

        showVariants = false
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

    /// 液态玻璃"容器"样式（地址栏）
    @ViewBuilder
    func browserGlassBar(cornerRadius: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
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