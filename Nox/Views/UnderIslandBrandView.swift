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
    private static let markHeight: CGFloat = 24
    private static let dynamicIslandMinimumInset: CGFloat = 55

    /// 与灵动岛硬件尺寸一致的外框（约 126×37pt，顶部距屏幕边缘约 11pt）。
    private static let islandSize = CGSize(width: 126, height: 37)
    private static let islandCenterY: CGFloat = 11 + 37 / 2

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
        outlineView.layer.cornerRadius = Self.islandSize.height / 2
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

        let font = UIFont(name: "AvenirNext-DemiBold", size: 11)
            ?? UIFont.systemFont(ofSize: 11, weight: .semibold)
        // 前景色交给 UILabel.textColor（动态颜色会跟随深浅色），
        // attributedText 只负责字体与字距。
        nameLabel.attributedText = NSAttributedString(
            string: "NOX",
            attributes: [
                .font: font,
                .kern: 1.2
            ]
        )
        nameLabel.textColor = UIColor.label.withAlphaComponent(0.86)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(nameLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Self.markHeight),
            iconView.heightAnchor.constraint(equalToConstant: Self.markHeight),
            outlineView.centerXAnchor.constraint(equalTo: centerXAnchor),
            outlineView.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.islandCenterY),
            outlineView.widthAnchor.constraint(equalToConstant: Self.islandSize.width),
            outlineView.heightAnchor.constraint(equalToConstant: Self.islandSize.height),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: outlineView.centerYAnchor)
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
