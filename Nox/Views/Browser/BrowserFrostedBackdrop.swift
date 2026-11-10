import SwiftUI
import UIKit

/// One live backdrop, with no painted background. Only the blur is masked.
struct BrowserFrostedBackdrop: UIViewRepresentable {
    let safeAreaHeight: CGFloat
    let addressBarHeight: CGFloat
    let topStrength: Double

    func makeUIView(context: Context) -> FrostedView { FrostedView() }
    func updateUIView(_ view: FrostedView, context: Context) {
        view.safeAreaHeight = safeAreaHeight
        view.addressBarHeight = addressBarHeight
        view.topStrength = topStrength
        view.setNeedsLayout()
    }

    final class FrostedView: UIVisualEffectView {
        var safeAreaHeight: CGFloat = 0
        var addressBarHeight: CGFloat = 0
        var topStrength: Double = 0
        private let gradient = CAGradientLayer()

        init() {
            super.init(effect: UIBlurEffect(style: .systemThickMaterial))
            isUserInteractionEnabled = false
            backgroundColor = .clear
            contentView.backgroundColor = .clear
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            layer.mask = gradient
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let total = max(1, safeAreaHeight + addressBarHeight)
            var colors: [CGColor] = []
            var locations: [NSNumber] = []
            let midpoint = min(total, max(0, safeAreaHeight / 2))
            // Sample both curves separately so the midpoint is an exact stop.
            for segment in 0...1 {
                for index in 0...32 {
                    if segment == 1 && index == 0 { continue }
                    let progress = Double(index) / 32
                    let start = segment == 0 ? 0 : midpoint
                    let end = segment == 0 ? midpoint : total
                    let strength = segment == 0
                        ? topStrength * (1 - 0.5 * Self.ease(progress, easeIn: true))
                        : topStrength * 0.5 * (1 - Self.ease(progress, easeIn: false))
                    colors.append(UIColor.black.withAlphaComponent(min(1, max(0, strength))).cgColor)
                    locations.append(NSNumber(value: Double(start + (end - start) * CGFloat(progress)) / Double(total)))
                }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.frame = bounds
            gradient.colors = colors
            gradient.locations = locations
            CATransaction.commit()
        }

        /// Standard ease-in (0.42, 0, 1, 1) and ease-out (0, 0, 0.58, 1).
        private static func ease(_ progress: Double, easeIn: Bool) -> Double {
            var low = 0.0
            var high = 1.0
            for _ in 0..<24 {
                let t = (low + high) / 2
                let x = 3 * (1 - t) * (1 - t) * t * (easeIn ? 0.42 : 0)
                    + 3 * (1 - t) * t * t * (easeIn ? 1 : 0.58) + t * t * t
                if x < progress { low = t } else { high = t }
            }
            let t = (low + high) / 2
            return 3 * t * t - 2 * t * t * t
        }
    }
}
