import UIKit

/// 藏在灵动岛硬件下方的小品牌标记。
///
/// 直接挂在窗口上、铺满顶部安全区并让内容垂直居中，因此：
/// - 正常使用时被灵动岛完全遮住；
/// - 系统截图不绘制挖孔，上划进入多任务、画面缩放时会露出来；
/// - 不参与 SwiftUI 布局，也不接收任何事件。
///
/// 只在灵动岛机型显示：灵动岛机型顶部安全区约 59–62pt，
/// 刘海机最大约 50pt，用 55pt 作为分界。
final class UnderIslandBrandView: UIView {
    private static let markHeight: CGFloat = 18
    private static let dynamicIslandMinimumInset: CGFloat = 55

    /// 灵动岛中心距屏幕顶部约 29.5pt。
    private static let islandCenterY: CGFloat = 11 + 37 / 2
    /// 紧贴图标和文字的边框内边距。
    private static let outlinePadding = UIEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)

    private let outlineView = UIView()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear

        outlineView.backgroundColor = .clear
        outlineView.layer.cornerRadius = Self.markHeight / 2 + Self.outlinePadding.top
        outlineView.layer.cornerCurve = .continuous
        outlineView.layer.borderWidth = 0.75
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outlineView)

        iconView.image = UIImage(named: "AppIconPreview")
        iconView.contentMode = .scaleAspectFill
        iconView.clipsToBounds = true
        iconView.layer.cornerRadius = Self.markHeight * 0.23
        iconView.layer.cornerCurve = .continuous
        iconView.layer.borderWidth = 0.5
        iconView.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let font = UIFont(name: "AvenirNext-DemiBold", size: 13)
            ?? UIFont.systemFont(ofSize: 13, weight: .semibold)
        // 前景色交给 UILabel.textColor（动态颜色会跟随深浅色），
        // attributedText 只负责字体与字距。
        nameLabel.attributedText = NSAttributedString(
            string: "NOX",
            attributes: [
                .font: font,
                .kern: 1.4
            ]
        )
        nameLabel.textColor = UIColor.label.withAlphaComponent(0.86)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 7
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(nameLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        outlineView.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Self.markHeight),
            iconView.heightAnchor.constraint(equalToConstant: Self.markHeight),
            outlineView.centerXAnchor.constraint(equalTo: centerXAnchor),
            outlineView.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.islandCenterY),
            stack.leadingAnchor.constraint(equalTo: outlineView.leadingAnchor, constant: Self.outlinePadding.left),
            stack.trailingAnchor.constraint(equalTo: outlineView.trailingAnchor, constant: -Self.outlinePadding.right),
            stack.topAnchor.constraint(equalTo: outlineView.topAnchor, constant: Self.outlinePadding.top),
            stack.bottomAnchor.constraint(equalTo: outlineView.bottomAnchor, constant: -Self.outlinePadding.bottom)
        ])

        applyBorderColor()
        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: UnderIslandBrandView, _) in
            view.applyBorderColor()
        }
    }

    private func applyBorderColor() {
        outlineView.layer.borderColor = UIColor.label.withAlphaComponent(0.18).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 窗口把本视图的高度约束成顶部安全区高度。
        isHidden = bounds.height < Self.dynamicIslandMinimumInset
    }
}
