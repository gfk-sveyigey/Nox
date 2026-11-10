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
            super.init(effect: UIBlurEffect(style: .systemUltraThinMaterial))
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
            if safeAreaHeight > 0 {
                for index in 0...32 {
                    let progress = Double(index) / 32
                    let strength = topStrength + (0.1 - topStrength) * Self.easeInOut(progress)
                    colors.append(UIColor.black.withAlphaComponent(min(1, max(0, strength))).cgColor)
                    locations.append(NSNumber(value: progress * Double(safeAreaHeight / total)))
                }
            } else {
                colors.append(UIColor.black.withAlphaComponent(0.1).cgColor)
                locations.append(0)
            }
            if addressBarHeight > 0 {
                colors.append(UIColor.clear.cgColor)
                locations.append(1)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.frame = bounds
            gradient.colors = colors
            gradient.locations = locations
            CATransaction.commit()
        }

        /// CSS/SwiftUI ease-in-out: cubic-bezier(0.42, 0, 0.58, 1).
        private static func easeInOut(_ progress: Double) -> Double {
            var low = 0.0
            var high = 1.0
            for _ in 0..<24 {
                let t = (low + high) / 2
                let x = 3 * (1 - t) * (1 - t) * t * 0.42
                    + 3 * (1 - t) * t * t * 0.58 + t * t * t
                if x < progress { low = t } else { high = t }
            }
            let t = (low + high) / 2
            return 3 * t * t - 2 * t * t * t
        }
    }
}
