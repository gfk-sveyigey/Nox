import SwiftUI
import UIKit

struct DownloadsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var manager: DownloadManager

    @State private var shareURL: URL?
    @State private var showingShare = false
    @State private var showingClearConfirmation = false

    init(appState: AppState) {
        self.appState = appState
        _manager = StateObject(wrappedValue: DownloadManager(appState: appState))
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.downloads.isEmpty {
                    ContentUnavailableView(
                        "暂无下载",
                        systemImage: "arrow.down.circle",
                        description: Text("在浏览页面解析视频后即可加入下载队列。")
                    )
                } else {
                    List {
                        ForEach(appState.downloads) { record in
                            DownloadRow(
                                record: record,
                                onShare: { url in
                                    shareURL = url
                                    showingShare = true
                                },
                                onRetry: { manager.retry($0) },
                                onCancel: { manager.cancel($0) }
                            )
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                manager.deleteFile(for: appState.downloads[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.downloads.contains(where: {
                        $0.status == .finished ||
                        $0.status == .failed ||
                        $0.status == .cancelled
                    }) {
                        Button("清理") {
                            showingClearConfirmation = true
                        }
                    }
                }
            }
            .alert("清理下载记录？", isPresented: $showingClearConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    appState.clearFinishedDownloads()
                }
            } message: {
                Text("已完成、失败和已取消的任务将从下载列表中移除。")
            }
            .sheet(isPresented: $showingShare) {
                if let url = shareURL {
                    ActivityView(activityItems: [url])
                }
            }
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
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .lineLimit(2)

                    Text("\(record.quality) · \(record.format.uppercased())")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if record.status == .queued || record.status == .downloading {
                    Button {
                        onCancel(record)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消下载")
                }
            }

            // The progress bar is always the last element of each row.
            ProgressView(value: displayProgress)
                .progressViewStyle(.linear)
                .tint(progressColor)
                .animation(.easeInOut(duration: 0.2), value: displayProgress)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            if record.status == .failed || record.status == .cancelled {
                Button {
                    onRetry(record)
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
            }

            if record.status == .finished, let url = record.fileURL {
                Button {
                    onShare(url)
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }

            if record.status != .downloading && record.status != .queued {
                Button(role: .destructive) {
                    // The parent list's swipe-to-delete remains available.
                    // Context menu intentionally only exposes retry/share here.
                } label: {
                    EmptyView()
                }
                .disabled(true)
                .hidden()
            }
        }
    }

    private var displayProgress: Double {
        switch record.status {
        case .finished:
            return 1
        case .failed:
            return max(record.progress, 0.05)
        case .cancelled:
            return max(record.progress, 0)
        case .queued, .downloading:
            return record.progress
        }
    }

    private var progressColor: Color {
        switch record.status {
        case .finished:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .gray
        case .queued, .downloading:
            return .accentColor
        }
    }

    private var iconColor: Color {
        switch record.status {
        case .finished:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        case .queued, .downloading:
            return .accentColor
        }
    }

    private var iconName: String {
        switch record.status {
        case .finished:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        case .cancelled:
            return "arrow.clockwise.circle"
        case .queued, .downloading:
            return "arrow.down.circle"
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
