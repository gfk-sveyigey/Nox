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

    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear

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
        nameLabel.attributedText = NSAttributedString(
            string: "NOX",
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label.withAlphaComponent(0.86),
                .kern: 1.2
            ]
        )

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
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
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
