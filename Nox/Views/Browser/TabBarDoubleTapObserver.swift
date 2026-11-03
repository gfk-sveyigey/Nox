import SwiftUI
import UIKit
import QuartzCore

/// 在系统 TabBar 上监听「浏览」标签的双击。
///
/// SwiftUI 的 `TabView` 不提供「再次点击当前标签」的回调，所以在 window 上
/// 挂一个不取消系统点击的 tap 手势；每次触摸时判断落点是否在「浏览」标签上。
///
/// 判定规则：
/// - 第一下必须发生在「浏览」已经选中时，才进入双击候选；
/// - 从别的 Tab 点过来的第一下只会清空候选，所以「切到浏览后立刻再点一下」
///   不会误触回顶部；
/// - 只有紧接着的第二下才会触发。
struct TabBarDoubleTapObserver: UIViewRepresentable {
    /// 两下之间允许的最长间隔。
    static let doubleTapInterval: CFTimeInterval = 0.45

    var onBrowseDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBrowseDoubleTap: onBrowseDoubleTap)
    }

    func makeUIView(context: Context) -> DetectorView {
        let view = DetectorView()
        view.isUserInteractionEnabled = false
        view.onEnterWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(in: window)
        }
        return view
    }

    func updateUIView(_ uiView: DetectorView, context: Context) {
        context.coordinator.onBrowseDoubleTap = onBrowseDoubleTap

        if let window = uiView.window {
            context.coordinator.attach(in: window)
        }
    }

    static func dismantleUIView(_ uiView: DetectorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class DetectorView: UIView {
        var onEnterWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onEnterWindow?(window) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBrowseDoubleTap: () -> Void

        private var recognizer: UITapGestureRecognizer?
        private var lastTapTime: CFTimeInterval = 0
        private var resetWorkItem: DispatchWorkItem?
        /// 记录“手指按下时”浏览页是否已经选中。不能等到抬手后再读，
        /// 否则从别的 Tab 点过来的那一下已经被系统切到浏览，会误当成第一下。
        private var touchBeganWhileBrowseSelected = false

        init(onBrowseDoubleTap: @escaping () -> Void) {
            self.onBrowseDoubleTap = onBrowseDoubleTap
        }

        func attach(in window: UIWindow) {
            guard recognizer?.view !== window else { return }

            detach()

            // 挂在 window 上而不是具体的 TabBarButton：下载页在编辑态会隐藏
            // TabBar，按钮可能被销毁重建；window 本身是稳定的。每次点击时再
            // 现场判断落点是不是「浏览」按钮。
            let recognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(handleTap(_:))
            )
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)

            self.recognizer = recognizer
        }

        func detach() {
            reset()
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            // VoiceOver 的双击用于激活当前元素，不能被这里抢走。
            guard !UIAccessibility.isVoiceOverRunning,
                  let window = gestureRecognizer.view as? UIWindow else {
                return false
            }

            let point = touch.location(in: window)
            guard let hit = window.hitTest(point, with: nil),
                  let tabBar = Self.ancestorTabBar(of: hit),
                  Self.isBrowseHit(hit, in: tabBar) else {
                return false
            }

            touchBeganWhileBrowseSelected = tabBar.selectedItem === tabBar.items?.first
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // VoiceOver 的双击用于激活当前元素，不能被这里抢走。
            !UIAccessibility.isVoiceOverRunning
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }

            // 以“按下时”的选中项为准：从别的 Tab 点过来的那一下，
            // 系统要到抬手后才切换，所以不能在这里读 selectedItem。
            let wasAlreadyOnBrowse = touchBeganWhileBrowseSelected
            touchBeganWhileBrowseSelected = false
            guard wasAlreadyOnBrowse else {
                reset()
                return
            }

            let now = CACurrentMediaTime()
            if lastTapTime > 0, now - lastTapTime <= TabBarDoubleTapObserver.doubleTapInterval {
                reset()
                onBrowseDoubleTap()
            } else {
                lastTapTime = now
                scheduleReset()
            }
        }

        private func scheduleReset() {
            resetWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.lastTapTime = 0
            }
            resetWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + TabBarDoubleTapObserver.doubleTapInterval,
                execute: workItem
            )
        }

        private func reset() {
            resetWorkItem?.cancel()
            resetWorkItem = nil
            lastTapTime = 0
            touchBeganWhileBrowseSelected = false
        }

        private static func ancestorTabBar(of view: UIView) -> UITabBar? {
            var current: UIView? = view
            while let candidate = current {
                if let tabBar = candidate as? UITabBar,
                   (tabBar.items?.count ?? 0) >= 2 {
                    return tabBar
                }
                current = candidate.superview
            }
            return nil
        }

        /// 判断触摸落点是否属于第一个「浏览」标签。
        ///
        /// 先用 accessibilityLabel 匹配，兼容新版系统把标签做成非 UIControl 的情况；
        /// 匹配不到再退回按位置找第一个可交互控件。
        private static func isBrowseHit(_ hit: UIView, in tabBar: UITabBar) -> Bool {
            if let title = tabBar.items?.first?.title, !title.isEmpty {
                var current: UIView? = hit
                while let view = current, view !== tabBar {
                    if (view.accessibilityLabel ?? "").contains(title) {
                        return true
                    }
                    current = view.superview
                }
            }

            guard let browseButton = browseButton(in: tabBar) else { return false }
            return hit === browseButton || hit.isDescendant(of: browseButton)
        }

        /// 找到 TabBar 中从左到右第一个可交互控件，也就是「浏览」按钮。
        private static func browseButton(in tabBar: UITabBar) -> UIView? {
            var controls: [UIView] = []

            func collect(_ view: UIView) {
                for subview in view.subviews {
                    if subview is UIControl {
                        controls.append(outerControl(for: subview, in: tabBar))
                    }
                    collect(subview)
                }
            }

            collect(tabBar)

            // 同一个按钮内部可能还有 UIControl，统一向上归到最外层按钮。
            var seen = Set<ObjectIdentifier>()
            let buttons = controls.filter { seen.insert(ObjectIdentifier($0)).inserted }

            let sorted = buttons.sorted {
                $0.convert($0.bounds, to: tabBar).minX
                    < $1.convert($1.bounds, to: tabBar).minX
            }

            // 优先按 TabBarItem 标题找，避免 iPad 上存在侧栏开关等前置控件时
            // 把第一个 UIControl 误认成「浏览」。
            if let title = tabBar.items?.first?.title, !title.isEmpty {
                if let matched = sorted.first(where: {
                    ($0.accessibilityLabel ?? "").contains(title)
                }) {
                    return matched
                }
            }

            return sorted.first
        }

        /// 把按钮内部的子控件归并到该按钮本身。
        private static func outerControl(for control: UIView, in tabBar: UITabBar) -> UIView {
            var result = control
            var current = control.superview

            while let view = current, view !== tabBar {
                if view is UIControl {
                    result = view
                }
                current = view.superview
            }

            return result
        }
    }
}
