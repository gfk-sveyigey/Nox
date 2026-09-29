import SwiftUI
import WebKit

struct VideoBrowserView: View {
    @EnvironmentObject private var appState: AppState

    @StateObject private var parser: VideoParser
    @ObservedObject private var downloads: DownloadManager

    @Binding private var requestedURL: URL?

    @State private var address = "https://www.pornhub.com/"
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

    // MARK: - 顶部工具栏

    private var browserToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                addressBar

                Button("打开") {
                    openAddress()
                }
                .browserGlassButton()
                .frame(height: controlHeight)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button {
                    Task {
                        await parse()
                    }
                } label: {
                    if isParsing {
                        ProgressView()
                            .frame(height: controlHeight)
                    } else {
                        Label("解析视频", systemImage: "arrow.down.circle")
                            .frame(height: controlHeight)
                    }
                }
                .browserGlassButton()
                .disabled(!parser.canParseCurrentPage || isParsing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)

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
            .navigationTitle(parsedVideo?.title ?? "选择清晰度")
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
        // 点击「打开」后收起键盘
        addressFocused = false

        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.contains("://") {
            text = "https://" + text
        }

        guard let url = URL(string: text), url.scheme == "https" else {
            errorMessage = "请输入 HTTPS 地址。"
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

            if appState.preferredQuality != "每次询问",
               let video = parsedVideo,
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
        preference: String
    ) -> VideoVariant? {
        if preference == "最佳" {
            return variants.max {
                qualityNumber($0.quality) < qualityNumber($1.quality)
            } ?? variants.first
        }

        return variants.first {
            $0.quality.localizedCaseInsensitiveContains(preference)
        } ?? variants.first
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