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
                .padding(.vertical, 4)
            }

            Section {
                ForEach(StorageCategory.allCases) { category in
                    row(for: category)
                }
            } footer: {
                Text(L("双指下滑进入多选，勾选要清理的类别，再点右上角「清理」。统计不含只读的 App 本体。"))
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
        .task { await refresh() }
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
        let downloads = (sizes[.videos] ?? 0) + (sizes[.documentsOther] ?? 0)
        let cache = (sizes[.parts] ?? 0)
            + (sizes[.staging] ?? 0)
            + (sizes[.networkCache] ?? 0)
            + (sizes[.temporary] ?? 0)
        let web = sizes[.websiteData] ?? 0
        let app = (sizes[.plugins] ?? 0)
            + (sizes[.logs] ?? 0)
            + (sizes[.preferences] ?? 0)
            + (sizes[.applicationOther] ?? 0)
            + (sizes[.applicationSupportOther] ?? 0)
            + (sizes[.libraryOther] ?? 0)
            + (sizes[.sharedContainer] ?? 0)

        return [
            StorageChartSlice(id: "downloads", title: L("下载"), bytes: downloads, color: .blue),
            StorageChartSlice(id: "cache", title: L("缓存"), bytes: cache, color: .orange),
            StorageChartSlice(id: "web", title: L("网站数据"), bytes: web, color: .green),
            StorageChartSlice(id: "app", title: L("应用数据"), bytes: app, color: .purple)
        ]
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
                StorageCategoryDetailView(manager: manager, category: category)
            } label: {
                categoryLabel(category)
            }
            .background(rowFrame(category))
        }
    }

    func categoryLabel(_ category: StorageCategory) -> some View {
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

            if categories.contains(.parts) { manager.clearParts() }
            if categories.contains(.staging) { manager.clearStaging() }
            if categories.contains(.logs) { LogStore.shared.clear() }
            if categories.contains(.networkCache) { manager.clearNetworkCache() }
            if categories.contains(.websiteData) { await manager.clearWebsiteData() }
            if categories.contains(.temporary) { manager.clearTemporaryFiles() }

            LogStore.shared.info(
                "storage cleared: " + categories.map(\.rawValue).sorted().joined(separator: ",")
            )

            refresh()
            manager.reconcileQueue()
        }
    }
}

/// 环形图：只统计 App 沙盒内的可写数据。
private struct StorageOverviewCard: View {
    let totalBytes: Int64
    let slices: [StorageChartSlice]

    private var chartTotal: Int64 {
        max(totalBytes, slices.reduce(0) { $0 + max($1.bytes, 0) })
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 24)

                ForEach(fractions) { item in
                    if item.end > item.start {
                        Circle()
                            .trim(from: item.start, to: item.end)
                            .stroke(
                                item.slice.color,
                                style: StrokeStyle(lineWidth: 24, lineCap: .butt)
                            )
                            .rotationEffect(.degrees(-90))
                    }
                }

                VStack(spacing: 4) {
                    Text(L("总计"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(TransferStats.formattedSize(totalBytes))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
            }
            .frame(width: 190, height: 190)

            VStack(spacing: 10) {
                ForEach(slices) { slice in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(slice.color)
                            .frame(width: 9, height: 9)

                        Text(slice.title)
                            .font(.subheadline)

                        Spacer(minLength: 8)

                        Text(TransferStats.formattedSize(slice.bytes))
                            .font(.subheadline)
                            .monospacedDigit()

                        Text(percentText(slice.bytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var fractions: [StorageChartFraction] {
        guard chartTotal > 0 else { return [] }
        var cursor: CGFloat = 0
        return slices.map { slice in
            let fraction = CGFloat(max(slice.bytes, 0)) / CGFloat(chartTotal)
            let start = cursor
            cursor += fraction
            return StorageChartFraction(
                slice: slice,
                start: start,
                end: min(cursor, 1)
            )
        }
    }

    private func percentText(_ bytes: Int64) -> String {
        guard chartTotal > 0 else { return "—" }
        return String(
            format: "%.0f%%",
            Double(max(bytes, 0)) / Double(chartTotal) * 100
        )
    }
}

/// 「储存空间」详情：显示该类别的直接子文件和子文件夹，文件夹可以继续进入。
struct StorageCategoryDetailView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var manager: DownloadManager
    let category: StorageCategory

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
        .task { await load() }
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
                StorageDirectoryDetailView(url: entry.url, title: entry.name)
            } label: {
                StorageEntryLabel(entry: entry)
            }
        } else {
            StorageEntryLabel(entry: entry)
        }
    }
}

/// 通用目录浏览：列出直接子项，文件夹可继续下钻。
struct StorageDirectoryDetailView: View {
    let url: URL
    let title: String

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
        .task { await load() }
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
                StorageDirectoryDetailView(url: entry.url, title: entry.name)
            } label: {
                StorageEntryLabel(entry: entry)
            }
        } else {
            StorageEntryLabel(entry: entry)
        }
    }
}

private struct StorageEntryLabel: View {
    let entry: StorageEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(.tint)
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

private struct StorageChartFraction: Identifiable {
    let slice: StorageChartSlice
    let start: CGFloat
    let end: CGFloat

    var id: String { slice.id }
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
