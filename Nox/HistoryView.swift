import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var showingClearConfirmation = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
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
                        description: Text(L("打开过的视频页面会显示在这里。"))
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
                }
            } message: {
                Text(L("所有浏览历史将被删除，此操作无法撤销。"))
            }
            .alert(L("删除所选？"), isPresented: $showingDeleteConfirmation) {
                Button(L("取消"), role: .cancel) {}
                Button(L("删除"), role: .destructive) {
                    appState.removeHistory(ids: selection)
                    selection.removeAll()

                    if appState.history.isEmpty { editMode = .inactive }
                }
            } message: {
                Text(String(format: L("将删除选中的 %d 条记录。"), selection.count))
            }
            .onChange(of: editMode) { _, newValue in
                if !newValue.isEditing { selection.removeAll() }
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            // 双指下滑进入多选（类似「信息」App）
            .twoFingerPanToSelect(isEnabled: isVisible) {
                withAnimation { editMode = .active }
            }
        }
    }

    /// 多选态才把选择绑给列表。
    ///
    /// 非多选态下单击列表行没有任何对应操作，绑上去只会留下「选中」高亮，
    /// 所以此时返回空集合并丢弃写入 —— 多选只能通过「选择」或双指下滑进入。
    private var listSelection: Binding<Set<UUID>> {
        Binding(
            get: { editMode.isEditing ? selection : [] },
            set: { newValue in
                guard editMode.isEditing else { return }
                selection = newValue
            }
        )
    }

    private var list: some View {
        List(selection: listSelection) {
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
                .tag(item.id)
                .contextMenu {
                    // 标题被截断成一行，长按时先把完整标题展示出来；
                    // 下面原有的菜单项保持不动。
                    Text(item.title)

                    Divider()

                    Button {
                        openInBrowser(item.url)
                    } label: {
                        Label(L("跳转网页"), systemImage: "safari")
                    }

                    Button {
                        UIPasteboard.general.string = item.url.absoluteString
                    } label: {
                        Label(L("复制链接"), systemImage: "doc.on.doc")
                    }

                    Divider()

                    Button(role: .destructive) {
                        appState.removeHistory(item)
                    } label: {
                        Label(L("删除记录"), systemImage: "trash")
                    }
                }
                // 与下载页一致的左滑删除；编辑态下 swipeActions 会自动失效
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        appState.removeHistory(item)
                    } label: {
                        Label(L("删除"), systemImage: "trash")
                    }
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

// MARK: - 双指下滑进入多选

/// 双指下滑进入多选（类似「信息」App）。
///
/// SwiftUI 的 `DragGesture` 拿不到触摸点数，只能落到 UIKit：往 window 上加一个
/// `minimumNumberOfTouches = 2` 的 `UIPanGestureRecognizer`，并设
/// `cancelsTouchesInView = false` —— 列表的单指滚动、行内点击都不受影响。
///
/// 放在本文件而不是新建文件，是为了避免再改手写的 `project.pbxproj`
/// （工程文件不会自动同步目录，新增文件必须手工登记，容易出错）。
struct TwoFingerPanToSelect: UIViewRepresentable {
    var isEnabled: Bool
    var onTrigger: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = DetectorView()
        view.isUserInteractionEnabled = false
        view.onEnterWindow = { window in
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTrigger = onTrigger
        context.coordinator.isEnabled = isEnabled

        if let window = uiView.window {
            context.coordinator.attach(to: window)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onTrigger: onTrigger)
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
        var onTrigger: () -> Void

        private weak var window: UIWindow?
        private var recognizer: UIPanGestureRecognizer?
        private var didFire = false
        /// 本次双指滑动是否从列表行上开始
        private var startedOnRow = false

        /// 向下拖动多少点才触发，避免与双指滚动混淆
        private let threshold: CGFloat = 40

        init(isEnabled: Bool, onTrigger: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onTrigger = onTrigger
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
        }

        @objc private func handle(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                didFire = false
                // 只有从列表行上开始的双指滑动才进入多选。
                // 在空白区域（列表下方、分组之间的间隙）滑动不应进入选择模式。
                startedOnRow = Self.startedOnRow(gesture)
            case .changed:
                guard isEnabled, startedOnRow, !didFire else { return }

                let translation = gesture.translation(in: gesture.view)

                guard translation.y > threshold,
                      abs(translation.y) > abs(translation.x) else { return }

                didFire = true
                onTrigger()
            default:
                didFire = false
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // 与列表自身的滚动手势并存，否则双指滑动会被 ScrollView 吃掉
            true
        }

        /// 命中测试：起点落在列表行上才算数。
        ///
        /// SwiftUI 的 List 底层是 UICollectionView（旧系统为 UITableView）：
        /// 先看是否有 cell 命中；命中结果是滚动视图本身时，再问它这个点有没有对应的
        /// item —— 空白区域（列表下方、分组之间的间隙）没有 item，于是不会进入选择模式。
        private static func startedOnRow(_ gesture: UIPanGestureRecognizer) -> Bool {
            guard let view = gesture.view else { return false }

            let point = gesture.location(in: view)
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
                    return collectionView.indexPathForItem(at: collectionView.convert(point, from: view)) != nil
                }

                if let tableView = current as? UITableView {
                    return tableView.indexPathForRow(at: tableView.convert(point, from: view)) != nil
                }

                hit = current.superview
            }

            return false
        }
    }
}

extension View {
    /// 双指下滑进入多选。`isEnabled` 建议与「本页是否可见」绑定，
    /// 免得在别的标签页上误触发。
    func twoFingerPanToSelect(isEnabled: Bool, action: @escaping () -> Void) -> some View {
        background(TwoFingerPanToSelect(isEnabled: isEnabled, onTrigger: action))
    }
}