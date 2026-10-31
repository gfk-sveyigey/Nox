import SwiftUI
import UIKit
import NoxCore
import NoxDownload
import NoxState

struct DownloadRow: View {
    let record: DownloadRecord
    let stats: TransferStats?
    /// 已完成的记录，但本地文件已经不在了（启动时扫描发现）
    let isMissingFile: Bool
    let onShare: (DownloadRecord) -> Void
    let onRetry: (DownloadRecord) -> Void
    let onCancel: (DownloadRecord) -> Void

    /// 编辑态下行内的按钮要收起来，否则点击会被按钮吃掉、选不中行
    @Environment(\.editMode) private var editMode

    init(
        record: DownloadRecord,
        stats: TransferStats?,
        isMissingFile: Bool,
        onShare: @escaping (DownloadRecord) -> Void,
        onRetry: @escaping (DownloadRecord) -> Void,
        onCancel: @escaping (DownloadRecord) -> Void
    ) {
        self.record = record
        self.stats = stats
        self.isMissingFile = isMissingFile
        self.onShare = onShare
        self.onRetry = onRetry
        self.onCancel = onCancel
    }

    var isEditing: Bool {
        editMode?.wrappedValue.isEditing ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading, spacing: 3) {
                    // 显示实际文件名（而非标题）—— 这才是「文件」App 里看到的名字。
                    // 列表里只占一行，超长部分用省略号（完整标题在长按菜单里）。
                    Text(record.displayFilename)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        // 清晰度与格式来自远端数据，不做本地化
                        Text(verbatim: "\(record.quality) · \(record.format.uppercased())")

                        // 实际并发数（普通下载 = 同时在飞的分片数，m3u8 = 分片并发）。
                        // 服务器不支持 Range 时会退化成单流，显示 1。
                        // 与左边的清晰度·格式同一种样式，数字在前，例如「4线程」
                        if let threads = record.threadCount {
                            Text(String(format: L("%d线程"), threads))
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
            // 标题被截断成一行，长按时先把完整标题展示出来；
            // 下面原有的菜单项保持不动。
            Text(record.displayFilename)

            Divider()

            if record.status == .failed || record.status == .cancelled {
                Button {
                    onRetry(record)
                } label: {
                    Label(retryTitle, systemImage: "arrow.clockwise")
                }
            }

            if record.status == .finished, record.hasLocalFile, !isMissingFile {
                Button {
                    onShare(record)
                } label: {
                    Label(L("分享"), systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    /// 暂停过就写「继续下载」，否则写「重试」
    var retryTitle: String {
        (record.receivedBytes ?? 0) > 0 ? L("继续下载") : L("重试")
    }

    @ViewBuilder
    var statusLine: some View {
        if record.status == .finished, isMissingFile {
            // 文件被系统清理或用户删除后，条目还在：明确提示缺失
            Label(L("文件缺失"), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if record.status == .downloading {
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

    var displayProgress: Double {
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

    var progressColor: Color {
        switch record.status {
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .gray
        case .queued, .downloading: return .accentColor
        }
    }

    var iconColor: Color {
        switch record.status {
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .queued, .downloading: return .accentColor
        }
    }

    var iconName: String {
        switch record.status {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "arrow.clockwise.circle"
        case .queued, .downloading: return "arrow.down.circle"
        }
    }
}

/// 从当前最上层视图控制器弹出系统分享面板。
