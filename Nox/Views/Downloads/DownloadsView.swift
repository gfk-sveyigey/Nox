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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if editMode.isEditing {
                    selectionFloatingActions
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea(edges: .bottom))
            .navigationTitle(L("下载"))
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, $editMode)
            .toolbar { toolbarContent }
            // 多选时隐藏底部标签栏，避免与悬浮操作按钮抢位置。
            .toolbar(editMode.isEditing ? .hidden : .visible, for: .tabBar)
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
    ///
    /// 退出时不要包在 `withAnimation` 里：标签栏重新出现、底部 `safeAreaInset`
    /// 同时收起时，两者的过渡会短暂叠出一块比页面更浅的背景。
    func finishSelection() {
        selection.removeAll()
        guard editMode.isEditing else { return }
        editMode = .inactive
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
            // 左侧红色减号按钮，与悬浮删除按钮重复。
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
        ToolbarItemGroup(placement: .topBarLeading) {
            if !appState.downloads.isEmpty {
                if editMode.isEditing {
                    // 多选态：完成与多功能菜单在左，全选/取消全选换到右侧。
                    Button {
                        finishSelection()
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel(L("完成"))

                    multiFunctionMenu
                } else {
                    Button(L("选择")) {
                        withAnimation { editMode = .active }
                    }
                }
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if !appState.downloads.isEmpty {
                if editMode.isEditing {
                    Button(allSelected ? L("取消全选") : L("全选")) {
                        withAnimation {
                            if allSelected {
                                selection.removeAll()
                            } else {
                                selection = Set(appState.downloads.map(\.id))
                            }
                        }
                    }
                } else {
                    multiFunctionMenu
                }
            }
        }
    }

    /// 下载页右上角（多选时移到左上角）的多功能菜单。
    ///
    /// 非多选态提供「全选」与「清空」；多选态整合批量操作。
    /// 菜单本身始终可用，即使没有选中项也会展开，只是不适用的操作置灰。
    @ViewBuilder
    var multiFunctionMenu: some View {
        Menu {
            if editMode.isEditing {
                Button {
                    manager.retryAll(ids: Set(retryableRecords.map(\.id)))
                    finishSelection()
                } label: {
                    Label(retryActionTitle, systemImage: "arrow.clockwise")
                }
                .disabled(retryableRecords.isEmpty)

                Button {
                    manager.cancelAll(ids: Set(pausableRecords.map(\.id)))
                    finishSelection()
                } label: {
                    Label(L("暂停"), systemImage: "pause.circle")
                }
                .disabled(pausableRecords.isEmpty)

                Divider()

                Button {
                    shareSelected()
                } label: {
                    Label(L("分享"), systemImage: "square.and.arrow.up")
                }
                .disabled(shareableRecords.isEmpty)
            } else {
                Button {
                    selectAllAndBeginSelection()
                } label: {
                    Label(L("全选"), systemImage: "checkmark.circle")
                }
            }

            if hasClearableDownloads {
                Divider()

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label(L("清空"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L("更多操作"))
    }

    func selectAllAndBeginSelection() {
        withAnimation {
            editMode = .active
            selection = Set(appState.downloads.map(\.id))
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

    var hasClearableDownloads: Bool {
        appState.downloads.contains {
            $0.status == .finished ||
            $0.status == .failed ||
            $0.status == .cancelled
        }
    }

    /// 多选态悬浮操作：左上角多功能菜单负责批量操作，右下角只保留删除。
    var selectionFloatingActions: some View {
        HStack(alignment: .center) {
            Spacer(minLength: 0)

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                circleLabel("trash", color: .red)
                    .opacity(selection.isEmpty ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
            .modifier(GlassCircleBackground())
            .accessibilityLabel(L("删除"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    func circleLabel(_ systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 52, height: 52)
            .contentShape(Circle())
    }

    /// 批量分享：只带上文件仍在的已完成记录。
    ///
    /// 先取出 URL 再退出多选；系统分享面板要等菜单退场后才能弹出，
    /// 提前清空 selection 不会影响这次分享。
    func shareSelected() {
        let urls = shareableRecords.compactMap { manager.shareableFileURL(for: $0) }
        finishSelection()

        guard !urls.isEmpty else {
            shareFailureMessage = L("文件不存在或已删除")
            showShareFailureAlert = true
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            SharePresenter.present(items: urls)
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

/// 多选态圆形按钮：iOS 26 使用系统液态玻璃，低版本回退到材质 + 描边。
private struct GlassCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.15), radius: 10, y: 3)
        }
    }
}
