import SwiftUI
import UIKit

/// 设置行左侧的图标 + 标题 + 说明。
///
/// 标题和说明都允许纵向换行；需要长期显示在右侧的内容可以覆盖在整行
/// 尾部并相对整行纵向居中，标题和说明则为它预留出所需宽度。
struct SettingsRowLabel: View {
    let title: String
    let subtitle: String?
    var systemImage: String? = nil
    var iconColor: Color = .accentColor
    /// 标题行右侧的附加内容（当前值、计数等）。
    var trailing: AnyView? = nil
    /// 覆盖在整行右侧、相对整行纵向居中的内容（picker 当前值）。
    var centeredTrailing: AnyView? = nil
    /// 为 `centeredTrailing` 预留的宽度，避免标题和说明被它盖住。
    var centeredTrailingReserve: CGFloat = 0

    var body: some View {
        Group {
            if let systemImage {
                Label {
                    textStack
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(iconColor)
                        .frame(width: 24, alignment: .center)
                }
            } else {
                textStack
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if let centeredTrailing {
                centeredTrailing
            }
        }
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                if let trailing {
                    trailing.layoutPriority(1)
                }
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, centeredTrailingReserve)
    }
}

struct SettingsPickerOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// 带右侧当前值的设置行。
///
/// 当前值覆盖在行尾并相对整行垂直居中，不参与标题行的高度计算；
/// 标题和说明只让出当前值所需的宽度。
struct SettingsPickerRow<Value: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var iconColor: Color = .accentColor
    @Binding var selection: Value
    let options: [SettingsPickerOption<Value>]

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? ""
    }

    /// 当前值（含箭头）的宽度，用来只给标题和说明让出必要的右侧空间。
    private var valueWidth: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let textWidth = (selectedTitle as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 18
    }

    private var valueView: some View {
        HStack(spacing: 4) {
            Text(selectedTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(width: valueWidth, alignment: .leading)
    }

    var body: some View {
        Menu {
            // 用系统菜单开关项：文字由系统排版，所有选项左端对齐，
            // 且只有当前选中项显示对勾。
            ForEach(options) { option in
                Toggle(isOn: Binding(
                    get: { option.value == selection },
                    set: { isOn in
                        if isOn { selection = option.value }
                    }
                )) {
                    Text(option.title)
                }
            }
        } label: {
            SettingsRowLabel(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconColor: iconColor,
                centeredTrailing: AnyView(valueView),
                centeredTrailingReserve: valueWidth + 8
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
