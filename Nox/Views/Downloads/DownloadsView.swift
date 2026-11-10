import SwiftUI
import UIKit
import NoxCore
import NoxDownload
import NoxState

struct TaskFilterAvailabilityPreference: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct DownloadsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var manager: DownloadManager
    @ObservedObject var localization = LocalizationManager.shared

    var menuRequest: UUID
    @State private var showingActionMenu = false

    @State var showingClearConfirmation = false
    @State private var detailsRecord: DownloadRecord?
    @State var shareFailureMessage: String?
    @State var showShareFailureAlert = false

    @State var editMode: EditMode = .inactive
    @State var selection = Set<UUID>()
    @State private var statusFilter: DownloadStatus?

    private let filterStatuses: [DownloadStatus] = [.notStarted, .queued, .downloading, .paused, .finished, .failed]

    var visibleRecords: [DownloadRecord] {
        appState.downloads.filter { statusFilter == nil || $0.status == statusFilter }
    }

    func statusTitle(_ status: DownloadStatus?) -> String {
        switch status {
        case .notStarted: return L("未开始")
        case .queued: return L("排队中")
        case .downloading: return L("下载中")
        case .paused: return L("已暂停")
        case .finished: return L("已完成")
        case .failed: return L("失败")
        default: return L("全部")
        }
    }

    var emptyStateTitle: String {
        guard let statusFilter else { return L("无任务") }
        switch statusFilter {
        case .notStarted: return L("无未开始任务")
        case .queued: return L("无排队中任务")
        case .downloading: return L("无进行中任务")
        case .paused: return L("无已暂停任务")
        case .finished: return L("无已完成任务")
        case .failed: return L("无失败任务")
        @unknown default: return L("无任务")
        }
    }
    /// 可见行的全局坐标，双指滑动时据此把路径映射到具体任务。
    @State var rowFrames: [UUID: CGRect] = [:]
    @State var showingDeleteConfirmation = false
    @State var isVisible = false
    /// 非多选态点按行时只闪一下，不留下持久选中。
    @State var tapFlashSelection = Set<UUID>()
    @State var tapFlashToken = UUID()

    init(appState: AppState, manager: DownloadManager, menuRequest: UUID) {
        self.menuRequest = menuRequest
        self.appState = appState
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                list
                if visibleRecords.isEmpty {
                    GeometryReader { geometry in
                        ContentUnavailableView {
                            Label {
                                Text(emptyStateTitle)
                                    .font(.title2.weight(.regular))
                            } icon: {
                                Image(systemName: "arrow.down.circle")
                            }
                        } description: {
                            EmptyView()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // The available area excludes the navigation and tab bars.
                        // Restore the full-screen center using the actual safe-area insets.
                        .offset(y: (geometry.safeAreaInsets.bottom - geometry.safeAreaInsets.top) / 2)
                    }
                    .allowsHitTesting(false)
                }
            }
            // 空列表时也把顶部安全区铺满分组背景，避免导航栏上方露出一条浅色空白。
            .background(pageBackgroundColor.ignoresSafeArea())
            .navigationTitle(L("任务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(pageBackgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .environment(\.editMode, $editMode)
            .preference(key: TaskFilterAvailabilityPreference.self, value: !visibleRecords.isEmpty)
            .toolbar {
                if !appState.downloads.isEmpty { toolbarContent }
            }
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
            .sheet(item: $detailsRecord) { record in
                DownloadDetailsView(taskID: record.id, appState: appState, manager: manager)
            }
            .onChange(of: menuRequest) { _, _ in
                guard !visibleRecords.isEmpty, !editMode.isEditing else { return }
                showingActionMenu = true
            }
            .sheet(isPresented: $showingActionMenu) {
                TaskOverviewView(records: appState.downloads,
                                 transfers: manager.transfers,
                                 storageBlocked: manager.storageBlocked)
            }
            .onChange(of: editMode) { _, newValue in
                if !newValue.isEditing {
                    selection.removeAll()
                } else {
                    tapFlashSelection.removeAll()
                }
            }
            .onChange(of: statusFilter) { _, _ in
                finishSelection()
                tapFlashSelection.removeAll()
                rowFrames.removeAll()
            }
            .onChange(of: visibleRecords.map(\.id)) { _, ids in
                selection.formIntersection(Set(ids))
                if ids.isEmpty { finishSelection() }
            }
            .onAppear {
                isVisible = true
                manager.refreshMissingFiles()
            }
            .onDisappear {
                isVisible = false
                tapFlashSelection.removeAll()
            }
            // 双指滑动：进入多选，并按滑过的路径选中任务。
            .twoFingerPanToSelect(
                isEnabled: isVisible && !visibleRecords.isEmpty,
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
        guard !visibleRecords.isEmpty, !editMode.isEditing else { return }
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
    /// 退出时不要包在 `withAnimation` 里：标签栏重新出现、底部工具栏
    /// 同时收起时，两者的过渡会短暂叠出一块比页面更浅的背景。
    func finishSelection() {
        selection.removeAll()
        guard editMode.isEditing else { return }
        editMode = .inactive
    }

    var list: some View {
        List(selection: listSelection) { rows }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 20, for: .scrollContent)
            .listSectionSpacing(12)
            .onPreferenceChange(SelectableRowFrameKey.self) { rowFrames = $0 }
            // 空间不足提示随可用空间出现/消失，用淡入淡出而不是列表默认的行插入动画。
            .animation(.easeInOut(duration: 0.26), value: manager.storageBlocked)
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
        ForEach(visibleRecords) { record in
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
                onPause: { record in manager.pause(record); finishSelection() },
                onDelete: { record in manager.deleteFile(for: record); finishSelection() },
                onDetails: { detailsRecord = $0 },
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
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { detailsRecord = record } label: {
                    Label(L("详细信息"), systemImage: "info.circle")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    manager.deleteFile(for: record)
                    finishSelection()
                } label: {
                    Label(L("删除"), systemImage: "trash")
                }
                if record.status != .finished {
                    if record.status != .notStarted && record.status != .legacyCancelled {
                        Button { manager.cancel(record) } label: {
                            Label(L("取消"), systemImage: "xmark.circle")
                        }
                        .tint(.orange)
                    }
                    Button {
                        if record.status == .queued || record.status == .downloading {
                            manager.pause(record)
                        } else { manager.retry(record) }
                    } label: {
                        Label(L(record.status == .queued || record.status == .downloading ? "暂停" : "继续"), systemImage: record.status == .queued || record.status == .downloading ? "pause" : "play")
                    }
                    .tint(.blue)
                }
            }
        }
    }

    struct TaskOverviewView: View {
        let records: [DownloadRecord]
        let transfers: [UUID: TransferStats]
        let storageBlocked: Bool
        @Environment(\.dismiss) private var dismiss
        @ObservedObject private var localization = LocalizationManager.shared

        private struct Metric: Identifiable {
            let title: String
            let count: Int
            let color: Color
            var id: String { title }
        }

        private var metrics: [Metric] {
            [
                Metric(title: "下载中", count: records.filter { $0.status == .downloading }.count, color: .accentColor),
                Metric(title: "未开始", count: records.filter { $0.status == .notStarted }.count, color: .secondary),
                Metric(title: "排队中", count: records.filter { $0.status == .queued }.count, color: .secondary),
                Metric(title: "已暂停", count: records.filter { $0.status == .paused }.count, color: .orange),
                Metric(title: "已完成", count: records.filter { $0.status == .finished }.count, color: .green),
                Metric(title: "失败", count: records.filter { $0.status == .failed }.count, color: .red)
            ].filter { $0.count > 0 }
        }

        private var speed: String {
            let total = records.filter { $0.status == .downloading }
                .reduce(0.0) { $0 + (transfers[$1.id]?.bytesPerSecond ?? 0) }
            return total > 0 ? TransferStats(bytesPerSecond: total).speedText : "0"
        }

        private var progress: Double {
            guard !records.isEmpty else { return 0 }
            return records.reduce(0.0) {
                $0 + ($1.status == .finished ? 1 : min(max($1.progress, 0), 1))
            } / Double(records.count)
        }

        private var totalCount: String {
            records.count.formatted(.number.locale(AppLocale.current))
        }

        var body: some View {
            NavigationStack {
                GeometryReader { geometry in
                    let spacing: CGFloat = 10
                    let horizontalPadding: CGFloat = 16
                    let availableWidth = max(0, geometry.size.width - horizontalPadding * 2)
                    let columns = max(1, Int((availableWidth + spacing) / (152 + spacing)))
                    let rows = (metrics.count + columns - 1) / columns

                    ScrollView {
                        VStack(spacing: 16) {
                            HStack(spacing: 10) {
                                summaryCard(title: L("任务总数"), value: totalCount,
                                            icon: "square.stack.3d.up.fill", tint: .indigo)
                                summaryCard(title: L("总速度"), value: speed,
                                            icon: "speedometer", tint: .blue)
                                summaryCard(title: L("总进度"),
                                            value: progress.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)),
                                            icon: "chart.pie.fill", tint: .green)
                            }

                            VStack(spacing: spacing) {
                                ForEach(0..<rows, id: \.self) { row in
                                    let start = row * columns
                                    let end = min(start + columns, metrics.count)
                                    HStack(spacing: spacing) {
                                        ForEach(Array(metrics[start..<end])) { metric in
                                            HStack(spacing: 11) {
                                                Image(systemName: icon(for: metric.title))
                                                    .font(.system(size: 18, weight: .semibold))
                                                    .foregroundStyle(metric.color)
                                                    .frame(width: 30, height: 30)
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(L(metric.title))
                                                        .font(.subheadline)
                                                        .foregroundStyle(.secondary)
                                                    Text(metric.count.formatted(.number.locale(AppLocale.current)))
                                                        .font(.title3.monospacedDigit().weight(.semibold))
                                                        .foregroundStyle(.primary)
                                                }
                                                Spacer(minLength: 0)
                                            }
                                            .padding(.horizontal, 13)
                                            .frame(maxWidth: .infinity, minHeight: 66)
                                            .background(Color(.secondarySystemGroupedBackground),
                                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
                                            }
                                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                        }
                                    }
                                }
                            }

                            if storageBlocked {
                                Label(L("储存空间不足"), systemImage: "externaldrive.fill.badge.exclamationmark")
                                    .font(.footnote.weight(.medium)).foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 14)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .animation(.easeInOut(duration: 0.24), value: metrics.map(\.count))
                    }
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle(L("任务总览"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("完成")) { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }

        private func summaryCard(title: String, value: String, icon: String, tint: Color) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Text(value)
                    .font(.title2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(.horizontal, 13)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
            }
        }

        private func icon(for title: String) -> String {
            switch title {
            case "下载中": return "arrow.down.circle.fill"
            case "未开始": return "circle.dashed"
            case "排队中": return "list.number"
            case "已暂停": return "pause.circle.fill"
            case "已完成": return "checkmark.circle.fill"
            default: return "exclamationmark.circle.fill"
            }
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if editMode.isEditing {
                Button {
                    finishSelection()
                } label: {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                }
                .accessibilityLabel(L("完成"))
            } else {
                Menu {
                    Picker(L("任务状态"), selection: $statusFilter) {
                        Text(L("全部")).tag(Optional<DownloadStatus>.none)
                        ForEach(filterStatuses, id: \.self) { status in
                            Text(statusTitle(status)).tag(Optional(status))
                        }
                    }
                } label: {
                    Label(statusTitle(statusFilter), systemImage: "line.3.horizontal.decrease")
                }
                .accessibilityLabel(L("筛选任务"))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu { taskMenuContents } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel(L("更多操作"))
            .disabled(visibleRecords.isEmpty)
        }
        if editMode.isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(allSelected ? L("取消全选") : L("全选")) {
                    withAnimation {
                        if allSelected {
                            selection.removeAll()
                        } else {
                            selection = Set(visibleRecords.map(\.id))
                        }
                    }
                }

                Spacer()

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selection.isEmpty)
                .accessibilityLabel(L("删除"))
            }
        }
    }

    /// All batch actions are scoped to the current filter and, in selection mode, selected rows.
    var actionRecords: [DownloadRecord] {
        editMode.isEditing ? selectedRecords : visibleRecords
    }

    var menuStatuses: Set<DownloadStatus> {
        Set(visibleRecords.map(\.status))
    }

    @ViewBuilder
    var taskMenuContents: some View {
            if !editMode.isEditing {
                Section {
                    Button {
                        showingActionMenu = false
                        withAnimation { editMode = .active }
                    } label: {
                        Label(L("选择"), systemImage: "checkmark.circle")
                    }
                    .disabled(visibleRecords.isEmpty)
                }
            }

            Section {
                if !menuStatuses.isDisjoint(with: [.notStarted, .paused, .failed]) {
                    Button {
                        showingActionMenu = false
                        manager.retryAll(ids: Set(actionRecords.filter {
                            [.notStarted, .paused, .failed].contains($0.status)
                        }.map(\.id)))
                        finishSelection()
                    } label: {
                        Label(L(editMode.isEditing ? "继续" : "全部继续"), systemImage: "arrow.clockwise")
                    }
                    .disabled(!actionRecords.contains { [.notStarted, .paused, .failed].contains($0.status) })
                }
                if !menuStatuses.isDisjoint(with: [.queued, .downloading]) {
                    Button {
                        showingActionMenu = false
                        manager.pauseAll(ids: Set(actionRecords.filter {
                            [.queued, .downloading].contains($0.status)
                        }.map(\.id)))
                        finishSelection()
                    } label: {
                        Label(L(editMode.isEditing ? "暂停" : "全部暂停"), systemImage: "pause.circle")
                    }
                    .disabled(!actionRecords.contains { [.queued, .downloading].contains($0.status) })
                }
                if !menuStatuses.isDisjoint(with: [.queued, .downloading, .paused, .failed]) {
                    Button {
                        showingActionMenu = false
                        manager.discardAll(ids: Set(actionRecords.filter {
                            [.queued, .downloading, .paused, .failed].contains($0.status)
                        }.map(\.id)))
                        finishSelection()
                    } label: {
                        Label(L(editMode.isEditing ? "取消" : "全部取消"), systemImage: "xmark.circle")
                    }
                    .disabled(!actionRecords.contains { [.queued, .downloading, .paused, .failed].contains($0.status) })
                }
            }

            if editMode.isEditing && menuStatuses.contains(.finished) {
                Section {
                    Button {
                        showingActionMenu = false
                        shareSelected()
                    } label: {
                        Label(L("分享"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(shareableRecords.isEmpty)
                }
            }

            Section {
                Button(role: .destructive) {
                    showingActionMenu = false
                    if !editMode.isEditing { selection = Set(visibleRecords.map(\.id)) }
                    showingDeleteConfirmation = true
                } label: {
                    Label(L(editMode.isEditing ? "删除" : "清空"), systemImage: "trash")
                }
                .disabled(actionRecords.isEmpty)
            }

    }

    // MARK: - 多选批量操作

    var selectedRecords: [DownloadRecord] {
        visibleRecords.filter { selection.contains($0.id) }
    }

    /// 已完成且本地文件仍在的任务可以分享。
    var shareableRecords: [DownloadRecord] {
        actionRecords.filter {
            $0.status == .finished &&
            !manager.missingFileIDs.contains($0.id) &&
            manager.shareableFileURL(for: $0) != nil
        }
    }

    var allSelected: Bool {
        !visibleRecords.isEmpty && selection == Set(visibleRecords.map(\.id))
    }

    var hasClearableDownloads: Bool {
        appState.downloads.contains {
            $0.status == .finished ||
            $0.status == .failed ||
            $0.status == .paused || $0.status == .notStarted
        }
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
