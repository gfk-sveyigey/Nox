import SwiftUI
import UIKit
import NoxCore
import NoxDownload
import NoxState


struct DownloadsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var manager: DownloadManager
    @ObservedObject var localization = LocalizationManager.shared

    @State var showingClearConfirmation = false
    @State var shareFailureMessage: String?
    @State var showShareFailureAlert = false

    @State var editMode: EditMode = .inactive
    @State var selection = Set<UUID>()
    /// 可见行的全局坐标，双指滑动时据此把路径映射到具体任务。
    @State var rowFrames: [UUID: CGRect] = [:]
    @State var showingDeleteConfirmation = false
    @State var isVisible = false

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
            .safeAreaInset(edge: .bottom) {
                if editMode.isEditing {
                    selectionActionsBar
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
                    finishSelection()
                }
            } message: {
                Text(L("已完成、失败和已取消的任务将被移除，同时删除对应的本地文件与未完成的分片。此操作无法撤销。"))
            }
            .alert(L("删除所选？"), isPresented: $showingDeleteConfirmation) {
                Button(L("取消"), role: .cancel) {}
                Button(L("删除"), role: .destructive) {
                    manager.deleteFiles(ids: selection)
                    finishSelection()
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
            // 双指滑动：进入多选，并按滑过的路径选中任务。
            .twoFingerPanToSelect(
                isEnabled: isVisible,
                onBegin: { beginTwoFingerSelection() },
                onPath: { selectRows(in: $0) }
            )
        }
    }

    /// 双指滑动开始时进入多选；已经在多选态时不重复触发动画。
    func beginTwoFingerSelection() {
        guard !editMode.isEditing else { return }
        withAnimation { editMode = .active }
    }

    /// 把双指滑过的路径映射到可见行；只增选，不反转已选项。
    func selectRows(in path: CGRect) {
        let ids = rowFrames.compactMap { id, frame in
            frame.intersects(path) ? id : nil
        }
        guard !ids.isEmpty else { return }
        selection.formUnion(ids)
    }

    /// 删除或其它操作完成后清理选择并退出多选。
    func finishSelection() {
        selection.removeAll()
        guard editMode.isEditing else { return }
        withAnimation { editMode = .inactive }
    }

    var list: some View {
        List(selection: listSelection) { rows }
            .onPreferenceChange(SelectableRowFrameKey.self) { rowFrames = $0 }
    }

    /// 非多选态忽略系统点选写入，避免单击行留下高亮；
    /// 同时始终复用同一个 List 身份，进入多选时不会重置滚动位置。
    var listSelection: Binding<Set<UUID>> {
        Binding(
            get: { selection },
            set: { newValue in
                guard editMode.isEditing else { return }
                selection = newValue
            }
        )
    }

    @ViewBuilder
    var rows: some View {
        ForEach(appState.downloads) { record in
            DownloadRow(
                record: record,
                stats: manager.transfers[record.id],
                isMissingFile: manager.missingFileIDs.contains(record.id),
                onShare: { record in
                    share(record)
                    finishSelection()
                },
                onRetry: { record in
                    manager.retry(record)
                    finishSelection()
                },
                onCancel: { record in
                    manager.cancel(record)
                    finishSelection()
                }
            )
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SelectableRowFrameKey.self,
                        value: [record.id: proxy.frame(in: .global)]
                    )
                }
            }
            .tag(record.id)
            // 用 swipeActions 而不是 onDelete：后者会让每行在编辑态多出一个
            // 左侧红色减号按钮，与底部操作栏的统一删除重复。
            // swipeActions 在编辑态自动失效，不影响多选。
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    manager.deleteFile(for: record)
                    finishSelection()
                } label: {
                    Label(L("删除"), systemImage: "trash")
                }
            }
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
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
                // 批量操作在底部操作栏；右上角只负责选择范围。
                Button(allSelected ? L("取消全选") : L("全选")) {
                    withAnimation {
                        if allSelected {
                            selection.removeAll()
                        } else {
                            selection = Set(appState.downloads.map(\.id))
                        }
                    }
                }
                .disabled(appState.downloads.isEmpty)
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

    // MARK: - 多选批量操作

    var selectedRecords: [DownloadRecord] {
        appState.downloads.filter { selection.contains($0.id) }
    }

    /// 失败 / 已暂停的任务可以重试或继续。
    var retryableRecords: [DownloadRecord] {
        selectedRecords.filter { $0.status == .failed || $0.status == .cancelled }
    }

    /// 排队中 / 下载中的任务可以暂停；分片已落盘，之后可继续。
    var pausableRecords: [DownloadRecord] {
        selectedRecords.filter { $0.status == .queued || $0.status == .downloading }
    }

    /// 已完成且本地文件仍在的任务可以分享。
    var shareableRecords: [DownloadRecord] {
        selectedRecords.filter {
            $0.status == .finished &&
            !manager.missingFileIDs.contains($0.id) &&
            manager.shareableFileURL(for: $0) != nil
        }
    }

    /// 全部选中项都已有下载进度时才写「继续下载」，否则写「重试」。
    var retryActionTitle: String {
        let records = retryableRecords
        guard !records.isEmpty else { return L("重试") }
        return records.allSatisfy { ($0.receivedBytes ?? 0) > 0 } ? L("继续下载") : L("重试")
    }

    var allSelected: Bool {
        !appState.downloads.isEmpty && selection.count == appState.downloads.count
    }

    /// 多选态底部操作栏。每个按钮只对选中项里状态适用的记录生效，
    /// 全部不适用时置灰，避免出现「点了没反应」。
    var selectionActionsBar: some View {
        HStack(spacing: 0) {
            actionButton(
                title: retryActionTitle,
                systemImage: "arrow.clockwise",
                isEnabled: !retryableRecords.isEmpty
            ) {
                manager.retryAll(ids: Set(retryableRecords.map(\.id)))
            }

            actionButton(
                title: L("暂停"),
                systemImage: "pause.circle",
                isEnabled: !pausableRecords.isEmpty
            ) {
                manager.cancelAll(ids: Set(pausableRecords.map(\.id)))
            }

            actionButton(
                title: L("分享"),
                systemImage: "square.and.arrow.up",
                isEnabled: !shareableRecords.isEmpty
            ) {
                shareSelected()
            }

            actionButton(
                title: L("删除"),
                systemImage: "trash",
                role: .destructive,
                isEnabled: !selection.isEmpty
            ) {
                showingDeleteConfirmation = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    func actionButton(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(actionButtonColor(role: role, isEnabled: isEnabled))
    }

    func actionButtonColor(role: ButtonRole?, isEnabled: Bool) -> Color {
        guard isEnabled else { return .secondary }
        return role == nil ? .accentColor : .red
    }

    /// 批量分享：只带上文件仍在的已完成记录。
    func shareSelected() {
        let urls = shareableRecords.compactMap { manager.shareableFileURL(for: $0) }
        guard !urls.isEmpty else {
            shareFailureMessage = L("文件不存在或已删除")
            showShareFailureAlert = true
            return
        }

        SharePresenter.present(items: urls)
    }

    /// 由长按菜单的「分享」触发。
    /// contextMenu 退场动画期间同步 present 会被系统静默丢弃（表现为点击无反应），
    /// 因此延后一拍再弹出系统分享面板。
    func share(_ record: DownloadRecord) {
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

