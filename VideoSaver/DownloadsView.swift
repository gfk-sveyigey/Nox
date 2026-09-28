import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var shareURL: URL?
    @State private var showingShare = false

    var body: some View {
        NavigationStack {
            Group {
                if appState.downloads.isEmpty {
                    ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle", description: Text("在浏览器中解析视频后即可加入下载队列。"))
                } else {
                    List {
                        ForEach(appState.downloads) { record in
                            DownloadRow(record: record, onShare: { url in shareURL = url; showingShare = true })
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let record = appState.downloads[index]
                                if let fileURL = record.fileURL { try? FileManager.default.removeItem(at: fileURL) }
                                appState.removeDownload(record)
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
    @EnvironmentObject private var appState: AppState
    let record: DownloadRecord
    let onShare: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).lineLimit(2)
                    Text("\(record.quality) · \(record.format.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusView
            }
            if record.status == .downloading || record.status == .queued {
                ProgressView(value: record.progress)
            }
            if let error = record.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if record.status == .finished, let url = record.fileURL {
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: fileSize(url), countStyle: .file))
                        .font(.caption)
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
        case .cancelled: return "xmark.circle"
        case .queued, .downloading: return "arrow.down.circle"
        }
    }

    @ViewBuilder private var statusView: some View {
        switch record.status {
        case .finished: Text("完成").foregroundStyle(.green)
        case .failed: Text("失败").foregroundStyle(.red)
        case .cancelled: Text("取消").foregroundStyle(.secondary)
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
