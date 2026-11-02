import SwiftUI
import UIKit
import NoxCore
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
    @Environment(\.scenePhase) private var scenePhase

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        List(selection: listSelection) {
            Section {
                StorageOverviewCard(
                    totalBytes: storageTotalSize,
                    slices: chartSlices
                )
                .padding(.vertical, 6)
            }

            Section {
                ForEach(clearableCategories) { category in
                    row(for: category)
                }
            } header: {
                Text(L("可清理"))
            }

            Section {
                ForEach(StorageCategory.protectedCategories) { category in
                    row(for: category)
                }
            } header: {
                Text(L("不可清理"))
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
        .task { await MainActor.run { refresh() } }
        .onChange(of: appState.downloads.count) { _, _ in refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
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

    @MainActor
    private var storageTotalSize: Int64 {
        StorageUsage.total(sizes)
    }

    @MainActor
    private var chartSlices: [StorageChartSlice] {
        StorageCategory.allCases.map { category in
            StorageChartSlice(
                id: category.rawValue,
                title: category.title,
                bytes: bytes(category),
                color: category.color
            )
        }
    }

    private func bytes(_ category: StorageCategory) -> Int64 {
        sizes[category] ?? 0
    }

    /// 回收站只在文件 App 真的留下内容时显示，避免固定多出一行空分类。
    private var clearableCategories: [StorageCategory] {
        StorageCategory.clearableCategories.filter { category in
            category != .trash || bytes(.trash) > 0
        }
    }

    private func fraction(for category: StorageCategory) -> CGFloat {
        guard storageTotalSize > 0 else { return 0 }
        return CGFloat(max(bytes(category), 0)) / CGFloat(storageTotalSize)
    }

    @ViewBuilder
    func row(for category: StorageCategory) -> some View {
        if editMode.isEditing {
            categoryLabel(category)
                .tag(category)
                .contentShape(Rectangle())
                .background(rowFrame(category))
                .selectionDisabled(!category.canClear)
        } else {
            NavigationLink {
                StorageCategoryDetailView(
                    manager: manager,
                    category: category,
                    tint: category.color
                )
            } label: {
                categoryLabel(category)
            }
            .background(rowFrame(category))
        }
    }

    func categoryLabel(_ category: StorageCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(category.color)
                .frame(width: 32, height: 32)
                .background(
                    category.color.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(category.title)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Text(TransferStats.formattedSize(bytes(category)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                StorageShareBar(
                    fraction: fraction(for: category),
                    color: category.color
                )
            }
        }
        .padding(.vertical, 2)
    }

    func rowFrame(_ category: StorageCategory) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: StorageRowFrameKey.self,
                value: [category: proxy.frame(in: .global)]
            )
        }
    }

    func beginTwoFingerSelection() {
        guard !editMode.isEditing else { return }
        withAnimation { editMode = .active }
    }

    func selectRows(in path: CGRect) {
        let categories = rowFrames.compactMap { category, frame in
            frame.intersects(path) && category.canClear ? category : nil
        }
        guard !categories.isEmpty else { return }
        selection.formUnion(categories)
    }

    func finishSelection() {
        selection.removeAll()
        guard editMode.isEditing else { return }
        withAnimation { editMode = .inactive }
    }

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

    @MainActor
    func refresh() {
        sizes = StorageUsage.snapshot(manager: manager)
    }

    func clearSelected() {
        let categories = selection
        finishSelection()

        Task {
            if categories.contains(.videos) {
                // 只删已完成的成品；正在下载的任务交给分片清理，避免打断下载。
                let finishedIDs = Set(
                    appState.downloads.filter { $0.status == .finished }.map(\.id)
                )
                manager.deleteFiles(ids: finishedIDs)
            }

            if categories.contains(.trash) { manager.clearTrash() }
            if categories.contains(.downloadTemporary) {
                manager.clearParts()
                manager.clearStaging()
            }
            if categories.contains(.caches) {
                manager.clearNetworkCache()
                manager.clearTemporaryFiles()
            }
            if categories.contains(.logs) { LogStore.shared.clear() }
            if categories.contains(.websiteData) { await manager.clearWebsiteData() }

            LogStore.shared.info(
                "storage cleared: " + categories.map(\.rawValue).sorted().joined(separator: ",")
            )

            refresh()
            manager.reconcileQueue()
        }
    }
}

/// 横向分段占比条：替代占用空间较大的环形图。
private struct StorageOverviewCard: View {
    let totalBytes: Int64
    let slices: [StorageChartSlice]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L("总计"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text(TransferStats.formattedSize(totalBytes))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
            }

            StorageSegmentedBar(slices: slices)
                .frame(height: 14)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 一条完整的 App 数据占比条，各分类按字节数比例着色。
private struct StorageSegmentedBar: View {
    let slices: [StorageChartSlice]

    private var totalBytes: Int64 {
        let sum = slices.reduce(Int64(0)) { partial, slice in
            partial + max(slice.bytes, 0)
        }
        return max(sum, 1)
    }

    private func segmentWidth(for slice: StorageChartSlice, available: CGFloat) -> CGFloat {
        let bytes = CGFloat(max(slice.bytes, 0))
        let total = CGFloat(totalBytes)
        return available * bytes / total
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(slices) { slice in
                    Rectangle()
                        .fill(slice.color)
                        .frame(width: segmentWidth(for: slice, available: proxy.size.width))
                }
            }
        }
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// 单个分类在总占用中的细进度条。
private struct StorageShareBar: View {
    let fraction: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.13))

                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

/// 「储存空间」详情：显示该类别的直接子文件和子文件夹，文件夹可以继续进入。
struct StorageCategoryDetailView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var manager: DownloadManager
    let category: StorageCategory
    var tint: Color = .accentColor

    @State var entries: [StorageEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    L("暂无文件"),
                    systemImage: "folder",
                    description: Text(L("这个类别当前没有占用。"))
                )
            } else {
                Section {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                } footer: {
                    Text(String(format: L("共 %@"), TransferStats.formattedSize(entryTotal)))
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await MainActor.run { load() } }
    }

    var entryTotal: Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    @MainActor
    func load() {
        entries = StorageUsage.children(
            for: category,
            manager: manager,
            records: appState.downloads
        )
    }

    @ViewBuilder
    func entryRow(_ entry: StorageEntry) -> some View {
        if entry.isDirectory {
            NavigationLink {
                StorageDirectoryDetailView(url: entry.url, title: entry.name, tint: tint)
            } label: {
                StorageEntryLabel(entry: entry, tint: tint)
            }
        } else {
            StorageEntryLabel(entry: entry, tint: tint)
        }
    }
}

/// 通用目录浏览：列出直接子项，文件夹可继续下钻。
struct StorageDirectoryDetailView: View {
    let url: URL
    let title: String
    var tint: Color = .accentColor

    @State var entries: [StorageEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    L("暂无文件"),
                    systemImage: "folder",
                    description: Text(L("这个文件夹是空的。"))
                )
            } else {
                Section {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                } footer: {
                    Text(String(format: L("共 %@"), TransferStats.formattedSize(entryTotal)))
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await MainActor.run { load() } }
    }

    var entryTotal: Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    @MainActor
    func load() {
        entries = StorageUsage.entries(in: url)
    }

    @ViewBuilder
    func entryRow(_ entry: StorageEntry) -> some View {
        if entry.isDirectory {
            NavigationLink {
                StorageDirectoryDetailView(url: entry.url, title: entry.name, tint: tint)
            } label: {
                StorageEntryLabel(entry: entry, tint: tint)
            }
        } else {
            StorageEntryLabel(entry: entry, tint: tint)
        }
    }
}

private struct StorageEntryLabel: View {
    let entry: StorageEntry
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(tint)
                .frame(width: 24)

            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(TransferStats.formattedSize(entry.bytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}

private struct StorageChartSlice: Identifiable {
    let id: String
    let title: String
    let bytes: Int64
    let color: Color
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
