import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState


struct SiteSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var pluginImport: PluginImportCoordinator
    @ObservedObject var localization = LocalizationManager.shared
    @ObservedObject var registry = VideoSiteParserRegistry.shared

    @State private var editMode: EditMode = .inactive
    @State private var actionError: String?
    @State private var pendingDeleteID: String?
    @State private var pendingDeleteName = ""
    @State private var pendingDeleteIsBundled = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            Section {
                ForEach(rows) { row in
                    rowView(row)
                        .contextMenu { contextMenu(for: row) }
                        .moveDisabled(row.isFixed)
                }
                .onMove { source, destination in
                    registry.move(fromOffsets: source, toOffset: destination)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        editMode.isEditing
                            ? L("拖动右侧手柄调整顺序；越靠前优先级越高，通用 Sniffer 固定最后。")
                            : L("越靠前优先级越高，通用 Sniffer 固定最后。")
                    )

                    if !editMode.isEditing {
                        Text(L("长按条目可导出或删除插件；内置插件删除后可在右上角恢复。"))
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(L("解析来源"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                trailingToolbar
            }
        }
        .alert(
            L("操作失败"),
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button(L("确定"), role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog(
            String(format: L("删除 %@？"), pendingDeleteName),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("删除插件"), role: .destructive) {
                deletePendingPlugin()
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(
                pendingDeleteIsBundled
                    ? L("这是随 App 分发的内置插件；确认后只会从本机解析来源中移除，可随时通过右上角菜单恢复。")
                    : L("只删除用户导入的插件文件；如果包内有同 id 插件，会回落到包内版本。")
            )
        }
    }

    @ViewBuilder
    private var trailingToolbar: some View {
        if editMode.isEditing {
            Button(L("完成")) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    editMode = .inactive
                }
            }
        } else {
            Menu {
                Button {
                    openPluginImporter()
                } label: {
                    Label(L("导入插件"), systemImage: "square.and.arrow.down")
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        editMode = .active
                    }
                } label: {
                    Label(L("调整顺序"), systemImage: "arrow.up.arrow.down")
                }

                Divider()

                Button {
                    registry.restoreDefaultOrder()
                } label: {
                    Label(L("恢复默认顺序"), systemImage: "arrow.counterclockwise")
                }
                .disabled(registry.parsers.count < 2)

                if PluginStore.shared.hasHiddenBundledPlugins {
                    Divider()

                    Button {
                        PluginStore.shared.restoreBundledPlugins()
                        registry.reload()
                    } label: {
                        Label(L("恢复内置插件"), systemImage: "arrow.uturn.backward.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(L("解析来源操作"))
        }
    }

    /// 从菜单里直接 present 会和菜单的收起动画抢同一个 presentation。
    /// 等菜单退场后再由最上层控制器呈现系统文档选择器。
    private func openPluginImporter() {
        let coordinator = pluginImport
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            PluginDocumentPicker.shared.present(
                onPick: { urls in
                    coordinator.importFiles(urls)
                },
                onCancel: {}
            )
        }
    }

    @ViewBuilder
    private func rowView(_ row: SiteRow) -> some View {
        if editMode.isEditing {
            // 排序态只保留拖动手柄，隐藏开关，避免误触改变启用状态。
            rowLabel(row)
        } else {
            Toggle(isOn: siteBinding(for: row.id)) {
                rowLabel(row)
            }
        }
    }

    private func rowLabel(_ row: SiteRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.systemImage)
                .foregroundStyle(row.isFixed ? Color.secondary : Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for row: SiteRow) -> some View {
        if row.isPlugin {
            Button {
                exportPlugin(row)
            } label: {
                Label(L("导出插件"), systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                pendingDeleteID = row.id
                pendingDeleteName = row.title
                pendingDeleteIsBundled = row.isBundled
                showDeleteConfirmation = true
            } label: {
                Label(L("删除插件"), systemImage: "trash")
            }

            Divider()
        }

        Button {
            UIPasteboard.general.string = row.id
        } label: {
            Label(L("复制插件 ID"), systemImage: "doc.on.doc")
        }
    }

    private func siteBinding(for identifier: String) -> Binding<Bool> {
        Binding(
            get: { appState.isSiteEnabled(identifier) },
            set: { appState.setSite(identifier, enabled: $0) }
        )
    }

    private func exportPlugin(_ row: SiteRow) {
        guard let url = PluginStore.shared.exportURL(for: row.id) else {
            actionError = L("无法导出该插件文件。")
            return
        }

        // 等长按菜单的收起动画开始后再弹分享面板，避免 UIKit 报
        // "presenting while a presentation is in progress"。
        DispatchQueue.main.async {
            SharePresenter.present(items: [url])
        }
    }

    private func deletePendingPlugin() {
        guard let identifier = pendingDeleteID else { return }
        pendingDeleteID = nil

        do {
            try PluginStore.shared.removePlugin(identifier: identifier)
            registry.reload()
            // 删除后清掉禁用状态；如果包内存在同 id 插件，它会恢复为可用。
            appState.setSite(identifier, enabled: true)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// 把解析器列表转成可 `ForEach` 的简单结构。
    private var rows: [SiteRow] {
        registry.parsers.map { parser in
            let fixed = parser.identifier == SnifferSite.identifier
            let info = rowPresentation(for: parser, fixed: fixed)
            return SiteRow(
                id: parser.identifier,
                title: parser.displayName,
                subtitle: info.subtitle,
                systemImage: info.systemImage,
                isPlugin: parser.isImportedPlugin || parser.isBundledPlugin,
                isBundled: parser.isBundledPlugin,
                isFixed: fixed
            )
        }
    }

    private func rowPresentation(
        for parser: VideoSiteParser,
        fixed: Bool
    ) -> (subtitle: String, systemImage: String) {
        if fixed {
            return (L("内置通用嗅探"), "dot.radiowaves.left.and.right")
        }

        // 所有单文件 .noxplugin 都按插件展示；区分包内版本与用户导入版本，
        // 这样导入一份与内置插件同 ID 的文件时，列表里能看出它已变成用户版本。
        if parser.isImportedPlugin || parser.isBundledPlugin {
            var parts = [
                parser.isImportedPlugin
                    ? L("已导入单文件插件")
                    : L("内置单文件插件")
            ]
            if let version = parser.pluginVersion, !version.isEmpty {
                parts.append("v\(version)")
            }
            if let author = parser.pluginAuthor, !author.isEmpty {
                parts.append(author)
            }
            return (parts.joined(separator: " · "), "puzzlepiece.extension")
        }

        return (L("内置解析器"), "bolt.horizontal.circle")
    }

    private struct SiteRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        let isPlugin: Bool
        let isBundled: Bool
        let isFixed: Bool
    }
}


/// 「储存空间」里可单独统计与清理的类别。
enum StorageCategory: String, CaseIterable, Identifiable {
    case videos
    case parts
    case staging
    case networkCache
    case websiteData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: return L("已下载视频")
        case .parts: return L("下载分片")
        case .staging: return L("临时文件")
        case .networkCache: return L("网络缓存")
        case .websiteData: return L("网站数据")
        }
    }

    var systemImage: String {
        switch self {
        case .videos: return "film"
        case .parts: return "square.split.2x2"
        case .staging: return "folder"
        case .networkCache: return "network"
        case .websiteData: return "globe"
        }
    }
}

/// 「储存空间」二级页：按类别展示占用。
///
/// 多选逻辑与「下载 / 历史」页保持一致：双指滑动进入多选，
/// 并沿滑动路径勾选类别，最后由右上角的「清理」统一清理。
