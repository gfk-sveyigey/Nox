import SwiftUI
import WebKit

struct VideoBrowserView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var parser: VideoParser
    @StateObject private var downloads: DownloadManager
    @State private var address = "https://www.pornhub.com/"
    @State private var parsedVideo: ParsedVideo?
    @State private var isParsing = false
    @State private var errorMessage: String?
    @State private var showVariants = false

    init(appState: AppState, initialURL: URL? = nil) {
        _parser = StateObject(wrappedValue: VideoParser(appState: appState))
        _downloads = StateObject(wrappedValue: DownloadManager(appState: appState))
        _initialURL = State(initialValue: initialURL)
    }

    @State private var initialURL: URL?

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
            .task {
                if let initialURL {
                    address = initialURL.absoluteString
                    parser.load(initialURL)
                    self.initialURL = nil
                }
            }
            .onChange(of: initialURL) { _, newURL in
                guard let newURL else { return }
                address = newURL.absoluteString
                parser.load(newURL)
                initialURL = nil
            }
            .sheet(isPresented: $showVariants) { variantSheet }
            .alert("解析失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("确定", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var browserToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("输入网页地址", text: $address)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { loadAddress() }
                Button("打开") { loadAddress() }
            }
            HStack {
                Button { parser.browserWebView.goBack() } label: { Image(systemName: "chevron.left") }
                Button { parser.browserWebView.goForward() } label: { Image(systemName: "chevron.right") }
                Button { parser.browserWebView.reload() } label: { Image(systemName: "arrow.clockwise") }
                Spacer()
                Button {
                    Task { await parse() }
                } label: {
                    if isParsing { ProgressView() } else { Label("解析视频", systemImage: "arrow.down.circle") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!parser.canParseCurrentPage || isParsing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showVariants = false } } }
        }
    }

    private func loadAddress() {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
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
            if appState.preferredQuality != "Ask Every Time",
               let variant = preferredVariant(parsedVideo!.variants, preference: appState.preferredQuality) {
                await download(variant)
            } else {
                showVariants = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preferredVariant(_ variants: [VideoVariant], preference: String) -> VideoVariant? {
        if preference == "Best" {
            return variants.max { qualityNumber($0.quality) < qualityNumber($1.quality) } ?? variants.first
        }
        return variants.first(where: { $0.quality.localizedCaseInsensitiveContains(preference) }) ?? variants.first
    }

    private func qualityNumber(_ quality: String) -> Int {
        let digits = quality.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    private func download(_ variant: VideoVariant) async {
        guard let parsedVideo else { return }
        let cookieHeader = await parser.cookieHeaderForCurrentPage()
        downloads.enqueue(title: parsedVideo.title, variant: variant, referer: parsedVideo.pageURL, cookieHeader: cookieHeader)
        showVariants = false
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
