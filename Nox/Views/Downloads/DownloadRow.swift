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
    let onPause: (DownloadRecord) -> Void
    let onDelete: (DownloadRecord) -> Void
    let onCancel: (DownloadRecord) -> Void

    /// 编辑态下行内的按钮要收起来，否则点击会被按钮吃掉、选不中行
    @Environment(\.editMode) private var editMode
    /// 行内的状态文案、菜单项都是纯 String，需要观察语言变化才会刷新。
    @ObservedObject private var localization = LocalizationManager.shared

    init(
        record: DownloadRecord,
        stats: TransferStats?,
        isMissingFile: Bool,
        onShare: @escaping (DownloadRecord) -> Void,
        onRetry: @escaping (DownloadRecord) -> Void,
        onPause: @escaping (DownloadRecord) -> Void,
        onDelete: @escaping (DownloadRecord) -> Void,
        onCancel: @escaping (DownloadRecord) -> Void
    ) {
        self.record = record
        self.stats = stats
        self.isMissingFile = isMissingFile
        self.onShare = onShare
        self.onRetry = onRetry
        self.onPause = onPause
        self.onDelete = onDelete
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
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    // 显示实际文件名（而非标题）—— 这才是「文件」App 里看到的名字。
                    // 列表里只占一行，超长部分用省略号（完整标题在长按菜单里）。
                    Text(record.displayFilename)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        // 清晰度/格式来自远端；旧记录里「页面嗅探」这类标签是按下载时的
                        // 语言存下的，displayQuality 会按当前语言重新翻译。
                        Text(verbatim: "\(record.displayQuality) · \(record.format.uppercased())")

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

            Button {
                if record.status == .queued || record.status == .downloading {
                    onPause(record)
                } else { onRetry(record) }
            } label: {
                Label(L(record.status == .queued || record.status == .downloading ? "暂停" : "继续"), systemImage: record.status == .queued || record.status == .downloading ? "pause" : "play")
            }
            .disabled(record.status == .finished)
            Button { onCancel(record) } label: {
                Label(L("取消"), systemImage: "xmark.circle")
            }
            .disabled(record.status == .finished)
            Button(role: .destructive) { onDelete(record) } label: {
                Label(L("删除"), systemImage: "trash")
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

    @ViewBuilder
    var statusLine: some View {
        if record.status == .finished, isMissingFile {
            // 文件被系统清理或用户删除后，条目还在：明确提示缺失
            Label(L("文件缺失"), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if record.status == .queued {
            Text(L("未开始"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if record.status == .downloading {
            let currentStats = stats ?? TransferStats()
            Text(String(format: L("下载中 · %@ · %@"), currentStats.sizeText, speedText(currentStats.bytesPerSecond)))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if record.status == .failed {
            Text(String(format: L("失败 · %@"), shortFailureReason))
                .font(.subheadline)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if record.status == .finished {
            Text(String(format: L("已完成 · %@"), TransferStats.formattedSize(record.receivedBytes ?? record.totalBytes ?? 0)))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if record.status == .cancelled, let received = record.receivedBytes, received > 0 {
            let size = TransferStats(bytesReceived: received, totalBytes: record.totalBytes ?? 0).sizeText
            Text(String(format: L("已暂停 · %@"), size))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if record.status == .cancelled {
            Text(L("未开始"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var shortFailureReason: String {
        guard let message = record.errorMessage, !message.isEmpty else { return L("未知错误") }
        let localizedPrefix = L("下载失败：%@").components(separatedBy: "%@").first ?? ""
        let prefixes = [localizedPrefix, "Download failed: ", "Download fehlgeschlagen: ", "Échec du téléchargement : ", "다운로드 실패: "]
        let prefix = prefixes.first { !$0.isEmpty && message.hasPrefix($0) }
        let reason = prefix.map { String(message.dropFirst($0.count)) } ?? message
        return reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speedText(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0" }
        return TransferStats(bytesPerSecond: bytesPerSecond).speedText
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
        case .queued: return .secondary
        case .downloading: return .accentColor
        }
    }

    var iconColor: Color {
        switch record.status {
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .queued: return .secondary
        case .downloading: return .accentColor
        }
    }

    var iconName: String {
        switch record.status {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return (record.receivedBytes ?? 0) > 0 ? "pause.circle.fill" : "xmark.circle.fill"
        case .queued: return "clock.badge"
        case .downloading: return "arrow.down.circle.fill"
        }
    }

}

/// 从当前最上层视图控制器弹出系统分享面板。
