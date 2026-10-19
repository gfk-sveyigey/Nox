import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var showingClearConfirmation = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    /// 可见行的全局坐标，双指滑动时据此把路径映射到具体记录。
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var showingDeleteConfirmation = false
    @State private var isVisible = false

    let openInBrowser: (URL) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if appState.history.isEmpty {
                    ContentUnavailableView(
                        L("暂无历史"),
                        systemImage: "clock",
                        description: Text(L("下载过的视频页面会显示在这里。"))
                    )
                } else {
                    list
                }
            }
            .navigationTitle(L("历史"))
            .navigationBarTitleDisplayMode(.inline)
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
                if !newValue.isEditing { selection.removeAll() }
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            // 双指滑动：进入多选，并按滑过的路径选中记录。
            .twoFingerPanToSelect(
                isEnabled: isVisible,
                onBegin: { beginTwoFingerSelection() },
                onPath: { selectRows(in: $0) }
            )
        }
    }

    /// 双指滑动开始时进入多选；已经在多选态时不重复触发动画。
    private func beginTwoFingerSelection() {
        guard !editMode.isEditing else { return }
        withAnimation { editMode = .active }
    }

    /// 把双指滑过的路径映射到可见行；只增选，不反转已选项。
    private func selectRows(in path: CGRect) {
        let ids = rowFrames.compactMap { id, frame in
            frame.intersects(path) ? id : nil
        }
        guard !ids.isEmpty else { return }
        selection.formUnion(ids)
    }

    /// 删除或其它操作完成后清理选择并退出多选。
    private func finishSelection() {
        selection.removeAll()
        guard editMode.isEditing else { return }
        withAnimation { editMode = .inactive }
    }

    private var list: some View {
        List(selection: listSelection) { rows }
            .onPreferenceChange(SelectableRowFrameKey.self) { rowFrames = $0 }
    }

    /// 非多选态忽略系统点选写入，避免单击行留下高亮；
    /// 同时始终复用同一个 List 身份，进入多选时不会重置滚动位置。
    private var listSelection: Binding<Set<UUID>> {
        Binding(
            get: { selection },
            set: { newValue in
                guard editMode.isEditing else { return }
                selection = newValue
            }
        )
    }

    @ViewBuilder
    private var rows: some View {
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
    private var toolbarContent: some ToolbarContent {
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
struct SelectableRowFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - 双指滑动进入多选

/// 双指滑动进入多选（类似「信息」App），并沿滑动路径选中记录。
///
/// SwiftUI 的 `DragGesture` 拿不到触摸点数，只能落到 UIKit：往 window 上加一个
/// `minimumNumberOfTouches = 2` 的 `UIPanGestureRecognizer`，并设
/// `cancelsTouchesInView = false` —— 列表的单指滚动、行内点击都不受影响。
///
/// 放在本文件而不是新建文件，是为了避免再改手写的 `project.pbxproj`
/// （工程文件不会自动同步目录，新增文件必须手工登记，容易出错）。
struct TwoFingerPanToSelect: UIViewRepresentable {
    var isEnabled: Bool
    var onBegin: () -> Void
    var onPath: (CGRect) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = DetectorView()
        view.isUserInteractionEnabled = false
        view.onEnterWindow = { window in
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegin = onBegin
        context.coordinator.onPath = onPath
        context.coordinator.isEnabled = isEnabled

        if let window = uiView.window {
            context.coordinator.attach(to: window)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onBegin: onBegin, onPath: onPath)
    }

    /// 视图真正进入窗口时回调一次。`updateUIView` 有可能早于入窗，
    /// 只靠它注册会漏掉，所以这里用 `didMoveToWindow` 兜底。
    final class DetectorView: UIView {
        var onEnterWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onEnterWindow?(window) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var onBegin: () -> Void
        var onPath: (CGRect) -> Void

        private weak var window: UIWindow?
        private var recognizer: UIPanGestureRecognizer?
        /// 本次手势是否已经从行上开始并进入选择。
        private var isSelecting = false
        /// 上一次两指覆盖的纵向范围，用来补上快速滑动跳过的行。
        private var lastMinY: CGFloat?
        private var lastMaxY: CGFloat?

        init(
            isEnabled: Bool,
            onBegin: @escaping () -> Void,
            onPath: @escaping (CGRect) -> Void
        ) {
            self.isEnabled = isEnabled
            self.onBegin = onBegin
            self.onPath = onPath
        }

        func attach(to window: UIWindow) {
            guard recognizer == nil else { return }

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.cancelsTouchesInView = false
            pan.delegate = self
            window.addGestureRecognizer(pan)

            self.window = window
            self.recognizer = pan
        }

        func detach() {
            if let recognizer {
                window?.removeGestureRecognizer(recognizer)
            }

            recognizer = nil
            window = nil
            reset()
        }

        @objc private func handle(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard isEnabled, Self.startedOnRow(gesture) else {
                    reset()
                    return
                }

                isSelecting = true
                lastMinY = nil
                lastMaxY = nil
                onBegin()
                reportPath(for: gesture, includePrevious: false)

            case .changed:
                guard isEnabled, isSelecting else { return }
                reportPath(for: gesture, includePrevious: true)

            default:
                reset()
            }
        }

        private func reset() {
            isSelecting = false
            lastMinY = nil
            lastMaxY = nil
        }

        /// 把两指当前覆盖的纵向范围、以及从上一次回调到现在的扫过范围交给列表。
        /// 这样即使滑得很快、跳过了几行，也不会漏选中间的记录。
        private func reportPath(for gesture: UIPanGestureRecognizer, includePrevious: Bool) {
            guard let view = gesture.view,
                  let current = Self.verticalRange(of: gesture, in: view) else { return }

            let minY: CGFloat
            let maxY: CGFloat
            if includePrevious, let lastMinY, let lastMaxY {
                minY = min(lastMinY, current.lowerBound)
                maxY = max(lastMaxY, current.upperBound)
            } else {
                minY = current.lowerBound
                maxY = current.upperBound
            }

            self.lastMinY = current.lowerBound
            self.lastMaxY = current.upperBound

            let rect = CGRect(
                x: 0,
                y: minY,
                width: view.bounds.width,
                height: max(1, maxY - minY)
            )
            onPath(rect)
        }

        /// 两指在 window 坐标系里的纵向范围。
        private static func verticalRange(
            of gesture: UIPanGestureRecognizer,
            in view: UIView
        ) -> ClosedRange<CGFloat>? {
            guard gesture.numberOfTouches > 0 else { return nil }

            var minY = CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude

            for index in 0..<gesture.numberOfTouches {
                let y = gesture.location(ofTouch: index, in: view).y
                minY = min(minY, y)
                maxY = max(maxY, y)
            }

            guard minY <= maxY else { return nil }
            return minY...maxY
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // 与列表自身的滚动手势并存，否则双指滑动会被 ScrollView 吃掉。
            true
        }

        /// 命中测试：任一手指起点落在列表行上才算数。
        private static func startedOnRow(_ gesture: UIPanGestureRecognizer) -> Bool {
            guard let view = gesture.view else { return false }

            if gesture.numberOfTouches == 0 {
                return isRow(at: gesture.location(in: view), in: view)
            }

            for index in 0..<gesture.numberOfTouches {
                let point = gesture.location(ofTouch: index, in: view)
                if isRow(at: point, in: view) { return true }
            }
            return false
        }

        private static func isRow(at point: CGPoint, in view: UIView) -> Bool {
            var hit = view.hitTest(point, with: nil)

            while let current = hit {
                if current is UITableViewCell || current is UICollectionViewCell {
                    return true
                }

                // SwiftUI 的列表 cell 是私有类型，类名判定作为兜底。
                if String(describing: type(of: current)).contains("Cell") {
                    return true
                }

                if let collectionView = current as? UICollectionView {
                    let localPoint = collectionView.convert(point, from: view)
                    return collectionView.indexPathForItem(at: localPoint) != nil
                }

                if let tableView = current as? UITableView {
                    let localPoint = tableView.convert(point, from: view)
                    return tableView.indexPathForRow(at: localPoint) != nil
                }

                hit = current.superview
            }

            return false
        }
    }
}

extension View {
    /// 双指滑动进入多选，并把滑过的路径报告给调用方。
    /// `isEnabled` 建议与「本页是否可见」绑定，免得在别的标签页上误触发。
    func twoFingerPanToSelect(
        isEnabled: Bool,
        onBegin: @escaping () -> Void,
        onPath: @escaping (CGRect) -> Void
    ) -> some View {
        background(
            TwoFingerPanToSelect(
                isEnabled: isEnabled,
                onBegin: onBegin,
                onPath: onPath
            )
        )
    }
}