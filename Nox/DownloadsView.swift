import SwiftUI
import UIKit

struct DownloadsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var manager: DownloadManager
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var showingClearConfirmation = false
    @State private var shareFailureMessage: String?
    @State private var showShareFailureAlert = false

    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var showingDeleteConfirmation = false
    @State private var isVisible = false

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
                    list
                }
            }
            .navigationTitle(L("下载"))
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, $editMode)
            .toolbar { toolbarContent }
            .alert(L("清空下载？"), isPresented: $showingClearConfirmation) {
                Button(L("取消"), role: .cancel) {}
                Button(L("清空"), role: .destructive) {
                    manager.clearFinished()
                }
            } message: {
                Text(L("已完成、失败和已取消的任务将被移除，同时删除对应的本地文件与未完成的分片。此操作无法撤销。"))
            }
            .alert(L("删除所选？"), isPresented: $showingDeleteConfirmation) {
                Button(L("取消"), role: .cancel) {}
                Button(L("删除"), role: .destructive) {
                    manager.deleteFiles(ids: selection)
                    selection.removeAll()

                    if appState.downloads.isEmpty { editMode = .inactive }
                }
            } message: {
                Text(String(format: L("将删除选中的 %d 项，同时删除对应的本地文件与未完成的分片。"),
                            selection.count))
            }
            .alert(L("分享失败"), isPresented: $showShareFailureAlert) {
                Button(L("确定"), role: .cancel) {}
            } message: {
                Text(shareFailureMessage ?? L("无法分享此文件"))
            }
            .onChange(of: editMode) { _, newValue in
                if !newValue.isEditing { selection.removeAll() }
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            // 双指下滑进入多选（类似「信息」App）
            .twoFingerPanToSelect(isEnabled: isVisible) {
                withAnimation { editMode = .active }
            }
        }
    }

    private var list: some View {
        List(selection: $selection) {
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
                .tag(record.id)
                // 用 swipeActions 而不是 onDelete：后者会让每行在编辑态多出一个
                // 左侧红色减号按钮，与「右上角统一删除」重复。
                // swipeActions 在编辑态自动失效，不影响多选。
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        manager.deleteFile(for: record)
                    } label: {
                        Label(L("删除"), systemImage: "trash")
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !appState.downloads.isEmpty {
                Button(editMode.isEditing ? L("完成") : L("选择")) {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if editMode.isEditing {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label(L("删除"), systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            } else if appState.downloads.contains(where: {
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

    /// 编辑态下行内的按钮要收起来，否则点击会被按钮吃掉、选不中行
    @Environment(\.editMode) private var editMode

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading, spacing: 3) {
                    // 显示实际文件名（而非标题）—— 这才是「文件」App 里看到的名字
                    Text(record.displayFilename)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        // 清晰度与格式来自远端数据，不做本地化
                        Text(verbatim: "\(record.quality) · \(record.format.uppercased())")

                        // 实际并发数（普通下载 = 同时在飞的分片数，m3u8 = 分片并发）。
                        // 服务器不支持 Range 时会退化成单流，显示 1。
                        if let threads = record.threadCount {
                            Text(String(format: L("线程 %d"), threads))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                if !isEditing,
                   record.status == .queued || record.status == .downloading {
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