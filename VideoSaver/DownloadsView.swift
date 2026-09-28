import SwiftUI

struct DownloadsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var manager: DownloadManager
    @State private var shareURL: URL?
    @State private var showingShare = false

    init(appState: AppState) {
        self.appState = appState
        _manager = StateObject(wrappedValue: DownloadManager(appState: appState))
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.downloads.isEmpty {
                    ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle", description: Text("在浏览页面解析视频后即可加入下载队列。"))
                } else {
                    List {
                        ForEach(appState.downloads) { record in
                            DownloadRow(record: record, onShare: { url in shareURL = url; showingShare = true }, onRetry: { manager.retry($0) }, onCancel: { manager.cancel($0) })
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let record = appState.downloads[index]
                                manager.deleteFile(for: record)
                            }
                        }
                    }
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.downloads.contains(where: { $0.status != .downloading && $0.status != .queued }) {
                        Button("清理") { appState.clearFinishedDownloads() }
                    }
                }
            }
            .sheet(isPresented: $showingShare) { if let url = shareURL { ActivityView(activityItems: [url]) } }
        }
    }
}

struct DownloadRow: View {
    let record: DownloadRecord
    let onShare: (URL) -> Void
    let onRetry: (DownloadRecord) -> Void
    let onCancel: (DownloadRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).lineLimit(2)
                    Text("\(record.quality) · \(record.format.uppercased())")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusView
            }
            if record.status == .downloading || record.status == .queued {
                ProgressView(value: record.progress)
                Button("取消") { onCancel(record) }
            }
            if let error = record.errorMessage {
                Text(error).foregroundStyle(.red).lineLimit(3)
                Button("重试") { onRetry(record) }
            }
            if record.status == .finished, let url = record.fileURL {
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: fileSize(url), countStyle: .file))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("分享") { onShare(url) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch record.status {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "arrow.clockwise.circle"
        case .queued, .downloading: return "arrow.down.circle"
        }
    }

    @ViewBuilder private var statusView: some View {
        switch record.status {
        case .finished: Text("完成").foregroundStyle(.green)
        case .failed: Text("失败").foregroundStyle(.red)
        case .cancelled: Text("已取消").foregroundStyle(.secondary)
        case .queued: Text("等待").foregroundStyle(.secondary)
        case .downloading: Text("\(Int(record.progress * 100))%")
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
