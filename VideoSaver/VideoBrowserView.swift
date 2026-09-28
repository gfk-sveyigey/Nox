import SwiftUI
import WebKit

struct VideoBrowserView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var parser: VideoParser
    @StateObject private var downloads: DownloadManager
    @State private var address = "https://www.pornhub.com/"
    @State private var parsedVideo: ParsedVideo?
    @State private var selectedVariant: VideoVariant?
    @State private var isParsing = false
    @State private var errorMessage: String?
    @State private var showVariants = false

    init(appState: AppState) {
        _parser = StateObject(wrappedValue: VideoParser(appState: appState))
        _downloads = StateObject(wrappedValue: DownloadManager(appState: appState))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                browserToolbar
                Divider()
                WebViewContainer(webView: parser.browserWebView)
            }
            .navigationTitle("浏览器")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showVariants) {
                variantSheet
            }
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
                .disabled(isParsing)
            }
        }
        .padding(10)
    }

    private var variantSheet: some View {
        NavigationStack {
            List(parsedVideo?.variants ?? []) { variant in
                Button {
                    selectedVariant = variant
                    Task {
                        if let parsedVideo {
                            let cookieHeader = await parser.cookieHeaderForCurrentPage()
                            downloads.enqueue(title: parsedVideo.title, variant: variant, referer: parsedVideo.pageURL, cookieHeader: cookieHeader)
                        }
                        showVariants = false
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(variant.displayName).font(.headline)
                            Text(variant.url.host ?? "media")
                                .font(.caption)
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
        isParsing = true
        defer { isParsing = false }
        do {
            let result = try await parser.parseCurrentPage()
            parsedVideo = result
            let preferred = result.variants.first(where: { $0.quality.localizedCaseInsensitiveContains(appState.preferredQuality) })
            selectedVariant = preferred ?? result.variants.first
            showVariants = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
