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
            .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
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

    private var list: some View {
        List(selection: $selection) {
            ForEach(appState.history) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
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
            if !editMode.isEditing, !appState.history.isEmpty {
                Button(L("清空")) {
                    showingClearConfirmation = true
                }
            }
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if editMode.isEditing, !selection.isEmpty {
            HStack(spacing: 10) {
                Text(String(format: L("已选 %d 项"), selection.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label(L("删除所选"), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
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
            case .changed:
                guard isEnabled, !didFire else { return }

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
    }
}

extension View {
    /// 双指下滑进入多选。`isEnabled` 建议与「本页是否可见」绑定，
    /// 免得在别的标签页上误触发。
    func twoFingerPanToSelect(isEnabled: Bool, action: @escaping () -> Void) -> some View {
        background(TwoFingerPanToSelect(isEnabled: isEnabled, onTrigger: action))
    }
}