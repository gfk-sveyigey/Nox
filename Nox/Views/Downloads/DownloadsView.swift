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
    /// 非多选态点按行时只闪一下，不留下持久选中。
    @State var tapFlashSelection = Set<UUID>()
    @State var tapFlashToken = UUID()
    let scrollToTopToken: Int

    init(appState: AppState, manager: DownloadManager, scrollToTopToken: Int = 0) {
        self.appState = appState
        _manager = ObservedObject(wrappedValue: manager)
        self.scrollToTopToken = scrollToTopToken
    }

    var body: some View {
        NavigationStack {
            Group {
                list
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if editMode.isEditing {
                    selectionFloatingActions
                }
            }
            // 空列表时也把顶部安全区铺满分组背景，避免导航栏上方露出一条浅色空白。
            .background(pageBackgroundColor.ignoresSafeArea())
            .navigationTitle(L("下载"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(pageBackgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
            // 双指滑动：进入多选，并按滑过的路径选中任务。
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
    ///
    /// 退出时不要包在 `withAnimation` 里：标签栏重新出现、底部 `safeAreaInset`
    /// 同时收起时，两者的过渡会短暂叠出一块比页面更浅的背景。
    func finishSelection() {
        selection.removeAll()
        guard editMode.isEditing else { return }
        editMode = .inactive
    }

    var list: some View {
        ScrollViewReader { proxy in
            List(selection: listSelection) { rows }
                .listStyle(.insetGrouped)
                .contentMargins(.top, 20, for: .scrollContent)
                .listSectionSpacing(12)
                .onPreferenceChange(SelectableRowFrameKey.self) { rowFrames = $0 }
                // 空间不足提示随可用空间出现/消失，用淡入淡出而不是列表默认的行插入动画。
                .animation(.easeInOut(duration: 0.26), value: manager.storageBlocked)
                .onChange(of: scrollToTopToken) { _, _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("downloads-overview", anchor: .top)
                    }
                }
        }
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
        Section {
            DownloadOverviewCard(
                records: appState.downloads,
                transfers: manager.transfers,
                storageBlocked: manager.storageBlocked
            )
            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            .listRowSeparator(.hidden)
            .id("downloads-overview")
        }

        if appState.downloads.isEmpty {
            ContentUnavailableView {
                Label {
                    Text(L("暂无下载"))
                        .font(.title2.weight(.regular))
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
            } description: {
                EmptyView()
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .listRowBackground(Color.clear)
        }

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
                onPause: { record in manager.pause(record); finishSelection() },
                onDelete: { record in manager.deleteFile(for: record); finishSelection() },
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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    manager.deleteFile(for: record)
                    finishSelection()
                } label: {
                    Label(L("删除"), systemImage: "trash")
                }
                if record.status != .finished {
                    Button { manager.cancel(record) } label: {
                        Label(L("取消"), systemImage: "xmark.circle")
                    }
                    .tint(.orange)
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

    struct DownloadOverviewCard: View {
        @Namespace private var statusAnimation

        private struct StatusMetric: Identifiable {
            let title: String
            let count: Int
            let color: Color
            var id: String { title }
        }

        let records: [DownloadRecord]
        let transfers: [UUID: TransferStats]
        let storageBlocked: Bool

        private var activeCount: Int { records.filter { $0.status == .downloading }.count }
        private var notStartedCount: Int {
            records.filter {
                $0.status == .notStarted
            }.count
        }
        private var queuedCount: Int { records.filter { $0.status == .queued }.count }
        private var pausedCount: Int {
            records.filter { $0.status == .paused }.count
        }
        private var finishedCount: Int { records.filter { $0.status == .finished }.count }
        private var failedCount: Int { records.filter { $0.status == .failed }.count }

        private var statusMetrics: [StatusMetric] {
            [
                StatusMetric(title: L("下载中"), count: activeCount, color: .accentColor),
                StatusMetric(title: L("未开始"), count: notStartedCount, color: .secondary),
                StatusMetric(title: L("排队中"), count: queuedCount, color: .secondary),
                StatusMetric(title: L("已暂停"), count: pausedCount, color: .orange),
                StatusMetric(title: L("已完成"), count: finishedCount, color: .green),
                StatusMetric(title: L("失败"), count: failedCount, color: .red)
            ].filter { $0.count > 0 }
        }

        private var statusGroups: [[StatusMetric]] {
            let metrics = statusMetrics
            guard metrics.count > 3 else { return metrics.isEmpty ? [] : [metrics] }
            let splitIndex = (metrics.count + 1) / 2
            return [Array(metrics[..<splitIndex]), Array(metrics[splitIndex...])]
        }

        private var animationKey: String {
            [activeCount, notStartedCount, queuedCount, pausedCount, finishedCount, failedCount]
                .map(String.init)
                .joined(separator: ":")
        }

        private var totalSpeed: String {
            let bytesPerSecond = records
                .filter { $0.status == .downloading }
                .reduce(0.0) { $0 + (transfers[$1.id]?.bytesPerSecond ?? 0) }
            guard bytesPerSecond > 0 else { return "0" }
            return TransferStats(bytesPerSecond: bytesPerSecond).speedText
        }

        private var totalProgress: Double {
            guard !records.isEmpty else { return 0 }
            return records.reduce(0.0) { sum, record in
                sum + (record.status == .finished ? 1 : min(max(record.progress, 0), 1))
            } / Double(records.count)
        }

        var body: some View {
            GeometryReader { geometry in
                let spacing: CGFloat = 8
                let groups = statusGroups
                let unitWidth = (geometry.size.width - spacing * CGFloat(groups.count))
                    / (1.5 + CGFloat(groups.count))

                HStack(alignment: .top, spacing: spacing) {
                    metricsCard
                        .frame(width: unitWidth * 1.5, height: 96, alignment: .leading)
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        statusCard(group)
                            .frame(width: unitWidth, height: 96, alignment: .topLeading)
                            .transition(.opacity)
                    }
                }
            }
            .frame(height: 96)
            .animation(.easeInOut(duration: 0.28), value: animationKey)
            .animation(.easeInOut(duration: 0.26), value: storageBlocked)
        }

        private var metricsCard: some View {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    metricValue(title: L("总速度"), value: totalSpeed)
                    metricValue(
                        title: L("总进度"),
                        value: "\(Int((totalProgress * 100).rounded()))%"
                    )
                }

                if storageBlocked {
                    Label {
                        Text(L("储存空间不足"))
                            .font(.footnote.weight(.medium))
                    } icon: {
                        Image(systemName: "externaldrive.fill.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private func statusCard(_ metrics: [StatusMetric]) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(metrics) { item in
                    countMetric(item.title, count: item.count, color: item.color)
                        .matchedGeometryEffect(id: item.id, in: statusAnimation)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private func metricValue(title: String, value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func countMetric(_ title: String, count: Int, color: Color) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(count)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if !appState.downloads.isEmpty {
                if editMode.isEditing {
                    // 主题色对号 = 完成，和系统「照片」的多选一致。
                    Button {
                        finishSelection()
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel(L("完成"))
                } else {
                    Button(L("选择")) {
                        withAnimation { editMode = .active }
                    }
                }
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if !appState.downloads.isEmpty {
                // 普通态与多选态都把多功能菜单放在右上角。
                multiFunctionMenu
            }
        }
    }

    /// 下载页右上角的多功能菜单。
    ///
    /// 非多选态提供全局继续 / 暂停 / 取消操作；
    /// 多选态整合针对选中项的批量操作。
    /// 菜单本身始终可用，即使没有选中项也会展开，只是不适用的操作置灰。
    @ViewBuilder
    var multiFunctionMenu: some View {
        Menu {
            if editMode.isEditing {
                Button {
                    manager.retryAll(ids: Set(retryableRecords.map(\.id)))
                    finishSelection()
                } label: {
                    Label(L("继续"), systemImage: "arrow.clockwise")
                }
                .disabled(retryableRecords.isEmpty)

                Button {
                    manager.pauseAll(ids: Set(pausableRecords.map(\.id)))
                    finishSelection()
                } label: {
                    Label(L("暂停"), systemImage: "pause.circle")
                }
                .disabled(pausableRecords.isEmpty)

                Button {
                    manager.discardAll(ids: Set(selectedRecords.filter { $0.status != .finished }.map(\.id)))
                    finishSelection()
                } label: {
                    Label(L("取消"), systemImage: "xmark.circle")
                }
                .disabled(selectedRecords.allSatisfy { $0.status == .finished })

                Divider()

                Button {
                    shareSelected()
                } label: {
                    Label(L("分享"), systemImage: "square.and.arrow.up")
                }
                .disabled(shareableRecords.isEmpty)
            } else {
                Button {
                    manager.retryAll(ids: Set(globalRetryableRecords.map(\.id)))
                } label: {
                    Label(L("继续"), systemImage: "arrow.clockwise")
                }
                .disabled(globalRetryableRecords.isEmpty)

                Button {
                    manager.pauseAll(ids: Set(globalPausableRecords.map(\.id)))
                } label: {
                    Label(L("暂停"), systemImage: "pause.circle")
                }
                .disabled(globalPausableRecords.isEmpty)

                Button {
                    manager.discardAll(ids: Set(appState.downloads.filter { $0.status != .finished }.map(\.id)))
                } label: {
                    Label(L("取消"), systemImage: "xmark.circle")
                }
                .disabled(appState.downloads.allSatisfy { $0.status == .finished })
            }

            Divider()
            Button(role: .destructive) {
                if !editMode.isEditing { selection = Set(appState.downloads.map(\.id)) }
                showingDeleteConfirmation = true
            } label: {
                Label(L("删除"), systemImage: "trash")
            }
            .disabled(editMode.isEditing ? selection.isEmpty : appState.downloads.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L("更多操作"))
    }

    // MARK: - 全局批量操作（非多选态）

    /// 失败 / 已暂停的全部任务，可一键继续。
    var globalRetryableRecords: [DownloadRecord] {
        appState.downloads.filter { $0.status == .failed || $0.status == .paused || $0.status == .notStarted }
    }

    /// 排队中 / 下载中的全部任务，可一键暂停。
    var globalPausableRecords: [DownloadRecord] {
        appState.downloads.filter { $0.status == .queued || $0.status == .downloading }
    }

    // MARK: - 多选批量操作

    var selectedRecords: [DownloadRecord] {
        appState.downloads.filter { selection.contains($0.id) }
    }

    /// 失败 / 已暂停的任务可以重试或继续。
    var retryableRecords: [DownloadRecord] {
        selectedRecords.filter { $0.status == .failed || $0.status == .paused || $0.status == .notStarted }
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

    var allSelected: Bool {
        !appState.downloads.isEmpty && selection.count == appState.downloads.count
    }

    var hasClearableDownloads: Bool {
        appState.downloads.contains {
            $0.status == .finished ||
            $0.status == .failed ||
            $0.status == .paused || $0.status == .notStarted
        }
    }

    /// 多选态悬浮操作：左下角全选 / 取消全选，右下角删除。
    var selectionFloatingActions: some View {
        HStack(alignment: .center) {
            Button {
                withAnimation {
                    if allSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(appState.downloads.map(\.id))
                    }
                }
            } label: {
                Text(allSelected ? L("取消全选") : L("全选"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .modifier(GlassCapsuleBackground())
            .accessibilityLabel(allSelected ? L("取消全选") : L("全选"))

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
            .frame(width: 44, height: 44)
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

/// 多选态文字按钮：与圆形玻璃按钮一致的液态玻璃效果，但使用胶囊形。
private struct GlassCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.15), radius: 10, y: 3)
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
