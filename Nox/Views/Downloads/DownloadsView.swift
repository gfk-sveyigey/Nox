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
            // 左侧红色减号按钮，与「右上角统一删除」重复。
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
                // 多选态：红色文字，和列表的删除语义一致。
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text(L("删除"))
                        .foregroundStyle(.red)
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

