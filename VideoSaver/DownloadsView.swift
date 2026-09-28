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
    @State private var bookmarks: [String] = []
    @State private var showBookmarks = false

    init(appState: AppState, downloads: DownloadManager, requestedURL: Binding<URL?>) {
        _parser = StateObject(wrappedValue: VideoParser(appState: appState))
        _downloads = ObservedObject(wrappedValue: downloads)
        _requestedURL = requestedURL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                browserToolbar

                WebViewContainer(webView: parser.browserWebView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadRequestedURLIfNeeded()
                loadBookmarks()
            }
            .onChange(of: requestedURL) { _, _ in
                loadRequestedURLIfNeeded()
            }
            .sheet(isPresented: $showVariants) {
                variantSheet
            }
            .sheet(isPresented: $showBookmarks) {
                bookmarksSheet
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

    private var browserToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("输入网页地址", text: $address)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        loadAddress()
                    }

                Button("打开") {
                    loadAddress()
                }
                .browserGlassButton()

                Button {
                    addBookmark()
                } label: {
                    Image(systemName: "star")
                }
                .browserGlassButton()

                Button {
                    showBookmarks = true
                } label: {
                    Image(systemName: "star.fill")
                }
                .browserGlassButton()
            }

            HStack(spacing: 4) {
                browserControlButton("chevron.left", enabled: parser.browserWebView.canGoBack) {
                    parser.browserWebView.goBack()
                }

                browserControlButton("chevron.right", enabled: parser.browserWebView.canGoForward) {
                    parser.browserWebView.goForward()
                }

                browserControlButton("arrow.clockwise", enabled: true) {
                    parser.browserWebView.reload()
                }

                Spacer(minLength: 4)

                Button {
                    Task { await parse() }
                } label: {
                    if isParsing {
                        ProgressView()
                            .frame(maxWidth: 16)
                    } else {
                        Label("解析视频", systemImage: "arrow.down.circle")
                    }
                }
                .browserGlassButton()
                .disabled(!parser.canParseCurrentPage || isParsing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func browserControlButton(
        _ systemName: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 28, height: 28)
                .font(.system(size: 14))
        }
        .browserGlassButton()
        .disabled(!enabled)
    }

    private var variantSheet: some View {
        NavigationStack {
            List(parsedVideo?.variants ?? []) { variant in
                Button {
                    Task { await download(variant) }
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

    private var bookmarksSheet: some View {
        NavigationStack {
            if bookmarks.isEmpty {
                ContentUnavailableView(
                    "暂无书签",
                    systemImage: "star",
                    description: Text("点击星标按钮保存网址。")
                )
                .navigationTitle("书签")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showBookmarks = false }
                    }
                }
            } else {
                List {
                    ForEach(bookmarks, id: \.self) { bookmark in
                        Button {
                            address = bookmark
                            parser.load(URL(string: bookmark) ?? URL(string: "https://")!)
                            showBookmarks = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bookmark)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(URL(string: bookmark)?.host ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        bookmarks.remove(atOffsets: indexSet)
                        saveBookmarks()
                    }
                }
                .navigationTitle("书签")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showBookmarks = false }
                    }
                }
            }
        }
    }

    private func loadRequestedURLIfNeeded() {
        guard let url = requestedURL else { return }

        requestedURL = nil
        address = url.absoluteString
        parser.load(url)
    }

    private func loadAddress() {
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

        isParsing = true
        defer { isParsing = false }

        do {
            parsedVideo = try await parser.parseCurrentPage()

            if appState.preferredQuality != "每次询问",
               let video = parsedVideo,
               let variant = preferredVariant(video.variants, preference: appState.preferredQuality) {
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

    private func addBookmark() {
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !bookmarks.contains(url) else { return }
        bookmarks.insert(url, at: 0)
        saveBookmarks()
    }

    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: "VideoBrowserBookmarks"),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            bookmarks = decoded
        }
    }

    private func saveBookmarks() {
        if let encoded = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(encoded, forKey: "VideoBrowserBookmarks")
        }
    }
}

private extension View {
    @ViewBuilder
    func browserGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

