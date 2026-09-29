import SwiftUI
import UIKit

struct DownloadsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var manager: DownloadManager
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var showingClearConfirmation = false
    @State private var shareFailureMessage: String?
    @State private var showShareFailureAlert = false

    init(appState: AppState, manager: DownloadManager) {
        self.appState = appState
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.downloads.isEmpty {
                    ContentUnavailableView(
                        L("暂无下载"),
                        systemImage: "arrow.down.circle",
                        description: Text(L("在浏览页面解析视频后即可加入下载队列。"))
                    )
                } else {
                    List {
                        ForEach(appState.downloads) { record in
                            DownloadRow(
                                record: record,
                                stats: manager.transfers[record.id],
                                onShare: { record in
                                    share(record)
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
            .navigationTitle(L("下载"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.downloads.contains(where: {
                        $0.status == .finished ||
                        $0.status == .failed ||
                        $0.status == .cancelled
                    }) {
                        Button(L("清空")) {
                            showingClearConfirmation = true
                        }
                    }
                }
            }
            .alert(L("清空下载？"), isPresented: $showingClearConfirmation) {
                Button(L("取消"), role: .cancel) {}
                Button(L("清空"), role: .destructive) {
                    manager.clearFinished()
                }
            } message: {
                Text(L("已完成、失败和已取消的任务将被移除，同时删除对应的本地文件与未完成的分片。此操作无法撤销。"))
            }
            .alert(L("分享失败"), isPresented: $showShareFailureAlert) {
                Button(L("确定"), role: .cancel) {}
            } message: {
                Text(shareFailureMessage ?? L("无法分享此文件"))
            }
        }
    }

    /// 由长按菜单的「分享」触发。
    /// contextMenu 退场动画期间同步 present 会被系统静默丢弃（表现为点击无反应），
    /// 因此延后一拍再弹出系统分享面板。
    private func share(_ record: DownloadRecord) {
        guard let url = manager.shareableFileURL(for: record) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                shareFailureMessage = L("文件不存在或已删除")
                showShareFailureAlert = true
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            SharePresenter.present(items: [url])
        }
    }
}

struct DownloadRow: View {
    let record: DownloadRecord
    let stats: TransferStats?
    let onShare: (DownloadRecord) -> Void
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

                    HStack(spacing: 6) {
                        // 清晰度与格式来自远端数据，不做本地化
                        Text(verbatim: "\(record.quality) · \(record.format.uppercased())")

                        // 实际并发数（普通下载 = 分片数，m3u8 = 分片并发）。
                        // 部分站点的媒体不支持 Range，这时会退化成单流，显示 1。
                        if let threads = record.threadCount {
                            Text(String(format: L("线程 %d"), threads))
                                .foregroundStyle(.tertiary)
                        }
                    }
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
                    .accessibilityLabel(L("取消下载"))
                }
            }

            ProgressView(value: displayProgress)
                .progressViewStyle(.linear)
                .tint(progressColor)
                .animation(.easeInOut(duration: 0.2), value: displayProgress)

            statusLine
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            if record.status == .failed || record.status == .cancelled {
                Button {
                    onRetry(record)
                } label: {
                    Label(retryTitle, systemImage: "arrow.clockwise")
                }
            }

            if record.status == .finished, record.hasLocalFile {
                Button {
                    onShare(record)
                } label: {
                    Label(L("分享"), systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    /// 暂停过就写「继续下载」，否则写「重试」
    private var retryTitle: String {
        (record.receivedBytes ?? 0) > 0 ? L("继续下载") : L("重试")
    }

    @ViewBuilder
    private var statusLine: some View {
        if record.status == .downloading {
            Text(stats?.displayText ?? TransferStats().displayText)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if record.status == .failed, let message = record.errorMessage {
            Text(verbatim: message)
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if record.status == .cancelled, let received = record.receivedBytes, received > 0 {
            Text(String(format: L("已暂停 · 已下载 %@，重试可继续"), TransferStats.formattedSize(received)))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .gray
        case .queued, .downloading: return .accentColor
        }
    }

    private var iconColor: Color {
        switch record.status {
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .queued, .downloading: return .accentColor
        }
    }

    private var iconName: String {
        switch record.status {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "arrow.clockwise.circle"
        case .queued, .downloading: return "arrow.down.circle"
        }
    }
}

/// 从当前最上层视图控制器弹出系统分享面板。
enum SharePresenter {
    static func present(items: [Any]) {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.windows
                .first(where: { $0.isKeyWindow })?
                .rootViewController
        else {
            return
        }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }

        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )

        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(
                x: top.view.bounds.midX,
                y: top.view.bounds.midY,
                width: 0,
                height: 0
            )
        }

        top.present(controller, animated: true)
    }
}