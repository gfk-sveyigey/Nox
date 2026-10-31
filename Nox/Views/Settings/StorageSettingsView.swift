import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState

struct StorageSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var localization = LocalizationManager.shared
    @ObservedObject var manager: DownloadManager

    @State var sizes: [StorageCategory: Int64] = [:]
    @State var editMode: EditMode = .inactive
    @State var selection = Set<StorageCategory>()
    @State var rowFrames: [StorageCategory: CGRect] = [:]
    @State var showingClearConfirmation = false
    @State var isVisible = false

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        List(selection: listSelection) {
            Section {
                ForEach(StorageCategory.allCases) { category in
                    row(for: category)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: StorageRowFrameKey.self,
                                    value: [category: proxy.frame(in: .global)]
                                )
                            }
                        }
                        .tag(category)
                }
            } header: {
                Text(L("储存空间"))
            } footer: {
                Text(L("双指下滑进入多选，勾选要清理的类别，再点右上角「清理」。清理网站数据会退出已登录的网站。"))
            }

            Section {
                LabeledContent(L("合计"), value: TransferStats.formattedSize(totalSize))
            }
        }
        .environment(\.editMode, $editMode)
        .onPreferenceChange(StorageRowFrameKey.self) { rowFrames = $0 }
        .navigationBarBackButtonHidden(editMode.isEditing)
        .navigationTitle(L("储存空间"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: editMode) { _, newValue in
            if !newValue.isEditing { selection.removeAll() }
        }
        .task { refresh() }
        .onChange(of: appState.downloads.count) { _, _ in refresh() }
        // 与下载 / 历史页一致：双指滑动进入多选，并按路径选中类别。
        .twoFingerPanToSelect(
            isEnabled: isVisible,
            onBegin: { beginTwoFingerSelection() },
            onPath: { selectRows(in: $0) }
        )
        .alert(L("清理所选？"), isPresented: $showingClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清理"), role: .destructive) { clearSelected() }
        } message: {
            Text(L("所选类别的缓存与文件将被删除，此操作无法撤销。"))
        }
    }

    /// 双指滑动开始时进入多选；已经在多选态时不重复触发动画。
    func beginTwoFingerSelection() {
        guard !editMode.isEditing else { return }
        withAnimation { editMode = .active }
    }

    /// 把双指滑过的路径映射到可见类别；只增选，不反转已选项。
    func selectRows(in path: CGRect) {
        let categories = rowFrames.compactMap { category, frame in
            frame.intersects(path) ? category : nil
        }
        guard !categories.isEmpty else { return }
        selection.formUnion(categories)
    }

    /// 清理完成后退出多选，避免停留在不可继续操作的选择状态。
    func finishSelection() {
        selection.removeAll()
        guard editMode.isEditing else { return }
        withAnimation { editMode = .inactive }
    }

    /// 多选态才把选择绑给列表（与下载 / 历史页相同的处理）。
    var listSelection: Binding<Set<StorageCategory>> {
        Binding(
            get: { editMode.isEditing ? selection : [] },
            set: { newValue in
                guard editMode.isEditing else { return }
                selection = newValue
            }
        )
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        // 多选只通过双指滑动进入；进入后在返回键的位置显示「完成」。
        ToolbarItem(placement: .topBarLeading) {
            if editMode.isEditing {
                Button(L("完成")) {
                    withAnimation { editMode = .inactive }
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if editMode.isEditing {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Text(L("清理"))
                        .foregroundStyle(.red)
                }
                .disabled(selection.isEmpty)
            } else {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L("刷新"))
            }
        }
    }

    func row(for category: StorageCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 26)

            Text(category.title)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Text(TransferStats.formattedSize(sizes[category] ?? 0))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    var totalSize: Int64 {
        sizes.values.reduce(0, +)
    }

    func refresh() {
        sizes = [
            .videos: manager.videosSize(),
            .parts: manager.partsSize(),
            .staging: manager.stagingSize(),
            .networkCache: manager.networkCacheSize(),
            .websiteData: manager.websiteDataSize()
        ]
    }

    func clearSelected() {
        let categories = selection
        finishSelection()

        Task {
            if categories.contains(.videos) {
                // 只删已完成的成品；正在下载的任务交给分片清理，避免打断下载
                let finishedIDs = Set(
                    appState.downloads.filter { $0.status == .finished }.map(\.id)
                )
                manager.deleteFiles(ids: finishedIDs)
            }

            if categories.contains(.parts) { manager.clearParts() }
            if categories.contains(.staging) { manager.clearStaging() }
            if categories.contains(.networkCache) { manager.clearNetworkCache() }
            if categories.contains(.websiteData) { await manager.clearWebsiteData() }

            LogStore.shared.info("storage cleared: " + categories.map(\.rawValue).sorted().joined(separator: ","))

            refresh()
        }
    }
}

/// 收集可见储存类别行的全局坐标，供双指路径选择使用。
private struct StorageRowFrameKey: PreferenceKey {
    static let defaultValue: [StorageCategory: CGRect] = [:]

    static func reduce(
        value: inout [StorageCategory: CGRect],
        nextValue: () -> [StorageCategory: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 「历史记录」二级页：保留方式（按条数 / 按时间）与具体数值。
