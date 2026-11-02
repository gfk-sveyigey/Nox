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
    @State var deviceTotalBytes: Int64 = 0
    @State var deviceFreeBytes: Int64 = 0
    @State var bundleBytes: Int64 = 0
    @Environment(\.scenePhase) private var scenePhase

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        List(selection: listSelection) {
            Section {
                StorageOverviewCard(
                    totalBytes: deviceTotalBytes,
                    freeBytes: deviceFreeBytes,
                    noxBytes: noxTotalSize,
                    otherBytes: otherAppsBytes
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

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
                Text(L("Nox 用量明细"))
            } footer: {
                Text(L("双指下滑进入多选，勾选要清理的类别，再点右上角「清理」。清理网站数据会退出已登录的网站。"))
            }

            Section {
                LabeledContent(L("Nox 合计"), value: TransferStats.formattedSize(noxTotalSize))
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
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

    /// Nox 占用的总空间：App 本体 + 下载文件 + 缓存与网站数据。
    var noxTotalSize: Int64 {
        totalSize + bundleBytes
    }

    /// 其他 App 与系统占用的空间。租用 / 系统预留空间也会落在这里。
    var otherAppsBytes: Int64 {
        max(deviceTotalBytes - deviceFreeBytes - noxTotalSize, 0)
    }

    func refresh() {
        let usage = DeviceStorage.usage()
        deviceTotalBytes = usage.totalBytes
        deviceFreeBytes = usage.freeBytes

        // App 本体不会在运行中变化，只算一次，避免每次刷新都遍历整个 bundle。
        if bundleBytes == 0 {
            bundleBytes = DeviceStorage.directorySize(at: Bundle.main.bundleURL)
        }

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
            // 释放空间后如果低于阈值的保护已经解除，立刻恢复排队任务。
            manager.reconcileQueue()
        }
    }
}

/// 整机储存空间概览：环形图 + 三项图例。
private struct StorageOverviewCard: View {
    let totalBytes: Int64
    let freeBytes: Int64
    let noxBytes: Int64
    let otherBytes: Int64

    private var usedBytes: Int64 {
        max(totalBytes - freeBytes, 0)
    }

    private var chartTotal: Int64 {
        max(totalBytes, noxBytes + otherBytes + freeBytes)
    }

    private var slices: [StorageSlice] {
        [
            StorageSlice(id: "nox", title: L("Nox"), bytes: noxBytes, color: .blue),
            StorageSlice(id: "other", title: L("其他应用与系统"), bytes: otherBytes, color: .orange),
            StorageSlice(id: "free", title: L("可用空间"), bytes: freeBytes, color: .green)
        ]
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("整机储存"))
                        .font(.headline)
                    Text(String(format: L("共 %@"), TransferStats.formattedSize(totalBytes)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(String(format: L("已用 %@"), TransferStats.formattedSize(usedBytes)))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 26)

                ForEach(fractions) { item in
                    if item.end > item.start {
                        Circle()
                            .trim(from: item.start, to: item.end)
                            .stroke(
                                item.slice.color,
                                style: StrokeStyle(lineWidth: 26, lineCap: .butt)
                            )
                            .rotationEffect(.degrees(-90))
                            .shadow(color: item.slice.color.opacity(0.15), radius: 3)
                    }
                }

                VStack(spacing: 4) {
                    Text(L("已用"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(TransferStats.formattedSize(usedBytes))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    Text(percentText(usedBytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 210, height: 210)
            .padding(.vertical, 4)

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
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var fractions: [StorageSliceFraction] {
        guard chartTotal > 0 else { return [] }
        var cursor: CGFloat = 0
        return slices.map { slice in
            let fraction = CGFloat(max(slice.bytes, 0)) / CGFloat(chartTotal)
            let start = cursor
            cursor += fraction
            return StorageSliceFraction(
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

private struct StorageSlice: Identifiable {
    let id: String
    let title: String
    let bytes: Int64
    let color: Color
}

private struct StorageSliceFraction: Identifiable {
    let slice: StorageSlice
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

/// 「历史记录」二级页：保留方式（按条数 / 按时间）与具体数值。
