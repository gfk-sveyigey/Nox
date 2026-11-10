import SwiftUI
import UIKit

/// Scroll to the resting position reached by dragging to the top, including content insets.
struct ScrollToPhysicalTop: UIViewRepresentable {
    let token: Int

    func makeUIView(context: Context) -> UIView { UIView() }
    func makeCoordinator() -> Coordinator { Coordinator(token: token) }
    func updateUIView(_ view: UIView, context: Context) {
        guard context.coordinator.token != token else { return }
        context.coordinator.token = token
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let container = ancestor {
                if let scroll = findScroll(in: container) {
                    scroll.setContentOffset(
                        CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top),
                        animated: true
                    )
                    return
                }
                ancestor = container.superview
            }
        }
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews where !child.isHidden && child.alpha > 0 {
            if let scroll = findScroll(in: child) { return scroll }
        }
        return nil
    }

    final class Coordinator {
        var token: Int
        init(token: Int) { self.token = token }
    }
}

/// Reject native reselection before UIKit performs its automatic single-tap scroll.
struct TabReselectionInterceptor: UIViewControllerRepresentable {
    let onReselect: (Int) -> Void

    func makeUIViewController(context: Context) -> ProbeController {
        let controller = ProbeController()
        controller.interceptor = context.coordinator
        return controller
    }
    func makeCoordinator() -> Coordinator { Coordinator(onReselect: onReselect) }
    func updateUIViewController(_ controller: ProbeController, context: Context) {
        context.coordinator.onReselect = onReselect
        controller.install()
    }

    final class ProbeController: UIViewController {
        var interceptor: Coordinator?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }
        func install() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let interceptor = self.interceptor else { return }
                var root: UIViewController = self
                while let parent = root.parent { root = parent }
                func findTab(_ controller: UIViewController) -> UITabBarController? {
                    if let tabs = controller as? UITabBarController { return tabs }
                    return controller.children.lazy.compactMap { findTab($0) }.first
                }
                guard let tabs = findTab(root) else { return }
                interceptor.installTapGuard(on: tabs)
                guard tabs.delegate !== interceptor else { return }
                interceptor.original = tabs.delegate
                tabs.delegate = interceptor
            }
        }
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate {
        private weak var tabs: UITabBarController?
        private var tapGuard: UITapGestureRecognizer?

        func installTapGuard(on tabs: UITabBarController) {
            self.tabs = tabs
            guard tapGuard?.view !== tabs.tabBar else { return }
            if let tapGuard { tapGuard.view?.removeGestureRecognizer(tapGuard) }
            let gesture = UITapGestureRecognizer(target: self, action: #selector(selectedTabTapped))
            gesture.delegate = self
            gesture.cancelsTouchesInView = true
            tabs.tabBar.addGestureRecognizer(gesture)
            tapGuard = gesture
        }

        @objc private func selectedTabTapped() {
            guard let tabs else { return }
            onReselect(tabs.selectedIndex)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let tabs, gestureRecognizer === tapGuard else { return false }
            // Only intercept an actual selected tab control, never blank space or
            // a different tab. This runs before UIKit can perform native reselection.
            var view = touch.view
            while let current = view, current !== tabs.tabBar {
                if let control = current as? UIControl,
                   control.isSelected || control.accessibilityTraits.contains(.selected) { return true }
                view = current.superview
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === tapGuard
        }

        weak var original: UITabBarControllerDelegate?
        var onReselect: (Int) -> Void
        init(onReselect: @escaping (Int) -> Void) { self.onReselect = onReselect }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            if viewController === tabBarController.selectedViewController {
                onReselect(tabBarController.selectedIndex)
                return false
            }
            return original?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
