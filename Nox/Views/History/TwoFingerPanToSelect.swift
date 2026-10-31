import SwiftUI
import UIKit
import NoxCore
import NoxState

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
