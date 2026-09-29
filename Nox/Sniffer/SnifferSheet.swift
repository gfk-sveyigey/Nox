import SwiftUI
import UIKit

/// 资源类型筛选项（对应原脚本的 图片 / 视频 / 音频 / 流媒体 四个标签）
enum SnifferKind: String, CaseIterable, Identifiable {
    case video
    case m3u8
    case audio
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return L("视频")
        case .m3u8: return L("流媒体")
        case .audio: return L("音频")
        case .image: return L("图片")
        }
    }

    var systemImage: String {
        switch self {
        case .video: return "play.rectangle"
        case .m3u8: return "dot.radiowaves.left.and.right"
        case .audio: return "waveform"
        case .image: return "photo"
        }
    }

    /// 该标签下要显示的 kind 集合。
    /// `stream`（MediaStream 直播）归到「视频」里，标注为直播即可。
    var kinds: Set<String> {
        switch self {
        case .video: return ["video", "stream"]
        case .m3u8: return ["m3u8"]
        case .audio: return ["audio"]
        case .image: return ["image"]
        }
    }
}

/// 半屏资源面板：重新扫描 / 按类型筛选 / 单项下载 / 复制链接。
///
/// 直接观察 `SnifferBridge.shared`，脚本后续上报的资源会实时出现在列表里。
struct SnifferSheet: View {
    @ObservedObject private var bridge = SnifferBridge.shared
    @ObservedObject private var localization = LocalizationManager.shared

    let onRescan: () async -> Void
    let onDownload: (SnifferBridge.Item) -> Void

    @State private var filter: SnifferKind = .video
    @State private var isRescanning = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L("资源类型"), selection: $filter) {
                    ForEach(SnifferKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                content
            }
            .navigationTitle(L("已嗅探"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            isRescanning = true
                            await onRescan()
                            isRescanning = false
                        }
                    } label: {
                        if isRescanning {
                            ProgressView()
                        } else {
                            Label(L("重新扫描"), systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRescanning)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("完成")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let items = bridge.items(matching: filter.kinds)

        if items.isEmpty {
            ContentUnavailableView(
                L("暂无资源"),
                systemImage: filter.systemImage,
                description: Text(L("页面加载或播放后会自动出现在这里。"))
            )
        } else {
            List {
                ForEach(items) { item in
                    Button {
                        onDownload(item)
                    } label: {
                        SnifferRow(item: item)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            UIPasteboard.general.string = item.url.absoluteString
                        } label: {
                            Label(L("复制链接"), systemImage: "doc.on.doc")
                        }
                        .tint(.indigo)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

private struct SnifferRow: View {
    let item: SnifferBridge.Item

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(item.qualityLabel)

                    if item.isLive {
                        Text(L("直播"))
                            .foregroundStyle(.red)
                    }

                    if let host = item.url.host {
                        Text("·")
                        Text(host).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)
        }
    }
}