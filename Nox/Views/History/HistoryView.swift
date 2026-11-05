import SwiftUI
import UIKit
import NoxCore
import NoxState


struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var localization = LocalizationManager.shared

    @State var showingClearConfirmation = false
    @State var editMode: EditMode = .inactive
    @State var selection = Set<UUID>()
    /// 可见行的全局坐标，双指滑动时据此把路径映射到具体记录。
    @State var rowFrames: [UUID: CGRect] = [:]
    @State var showingDeleteConfirmation = false
    @State var isVisible = false
    /// 非多选态点按时的短暂高亮：让用户看到「点到了」，但不会像多选一样留下选中。
    @State var tapFlashSelection = Set<UUID>()
    @State var tapFlashToken = UUID()

    let openInBrowser: (URL) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if appState.history.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text(L("暂无历史"))
                                .font(.title2.weight(.regular))
                        } icon: {
                            Image(systemName: "clock")
                        }
                    } description: {
                        EmptyView()
                    }
                } else {
                    list
                }
            }
            .background(pageBackgroundColor.ignoresSafeArea())
            .navigationTitle(L("历史"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(pageBackgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .environment(\.editMode, $editMode)
            .toolbar { toolbarContent }
            .alert(L("清空历史记录？"), isPresented: $showingClearConfirmation) {
                Button(L("取消"), role: .cancel) {}
                Button(L("清空"), role: .destructive) {
                    appState.clearHistory()
                    finishSelection()
                }
            } message: {
                Text(L("所有浏览历史将被删除，此操作无法撤销。"))
            }
            .alert(L("删除所选？"), isPresented: $showingDeleteConfirmation) {
                Button(L("取消"), role: .cancel) {}
                Button(L("删除"), role: .destructive) {
                    appState.removeHistory(ids: selection)
                    finishSelection()
                }
            } message: {
                Text(String(format: L("将删除选中的 %d 条记录。"), selection.count))
            }
            .onChange(of: editMode) { _, newValue in
                if !newValue.isEditing {
                    selection.removeAll()
                } else {
                    tapFlashSelection.removeAll()
                }
            }
            .onAppear { isVisible = true }
            .onDisappear {
                isVisible = false
                tapFlashSelection.removeAll()
            }
            // 双指滑动：进入多选，并按滑过的路径选中记录。
            .twoFingerPanToSelect(
                isEnabled: isVisible,
                onBegin: { beginTwoFingerSelection() },
                onPath: { selectRows(in: $0) }
            )
        }
    }

    /// 与设置页保持一致，空页面也使用分组列表背景色。
    var pageBackgroundColor: Color {
        Color(.systemGroupedBackground)
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

    /// 非多选态把行选中转成一次短暂高亮，随后自动清空；
    /// 同时在多选态才写真正的 `selection`。始终复用同一个 List 身份，
    /// 进入多选时不会重置滚动位置。
    var listSelection: Binding<Set<UUID>> {
        Binding(
            get: { editMode.isEditing ? selection : tapFlashSelection },
            set: { newValue in
                if editMode.isEditing {
                    selection = newValue
                    return
                }

                guard !newValue.isEmpty else { return }
                tapFlashSelection = newValue

                let token = UUID()
                tapFlashToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    guard tapFlashToken == token else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        tapFlashSelection.removeAll()
                    }
                }
            }
        )
    }

    @ViewBuilder
    var rows: some View {
        ForEach(appState.history) { item in
                VStack(alignment: .leading, spacing: 5) {
                    // 只占一行，超长部分用省略号（完整标题在长按菜单里）。
                    Text(item.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.url.absoluteString)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // Text(_:format:) 会走 .environment(\.locale)，
                    // Date.formatted() 不会，所以日期也跟着 App 语言变
                    Text(item.visitedAt, format: .dateTime.year().month().day().hour().minute())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SelectableRowFrameKey.self,
                            value: [item.id: proxy.frame(in: .global)]
                        )
                    }
                }
                .tag(item.id)
                .contextMenu {
                    // 标题被截断成一行，长按时先把完整标题展示出来；
                    // 下面原有的菜单项保持不动。
                    Text(item.title)

                    Divider()

                    Button {
                        openInBrowser(item.url)
                        finishSelection()
                    } label: {
                        Label(L("跳转网页"), systemImage: "safari")
                    }

                    Button {
                        UIPasteboard.general.string = item.url.absoluteString
                        finishSelection()
                    } label: {
                        Label(L("复制链接"), systemImage: "doc.on.doc")
                    }

                    Divider()

                    Button(role: .destructive) {
                        appState.removeHistory(item)
                        finishSelection()
                    } label: {
                        Label(L("删除记录"), systemImage: "trash")
                    }
                }
                // 与下载页一致的左滑删除；编辑态下 swipeActions 会自动失效
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        appState.removeHistory(item)
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
            if !appState.history.isEmpty {
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
            } else if !appState.history.isEmpty {
                Button(L("清空")) {
                    showingClearConfirmation = true
                }
            }
        }
    }
}

// MARK: - 双指滑动选择

/// 收集可见历史行的全局坐标；列表只保留可见行，坐标会随滚动自动更新。
