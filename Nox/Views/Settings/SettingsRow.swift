import SwiftUI

/// 设置行左侧的图标 + 标题 + 说明。
///
/// 标题和说明都允许纵向换行；需要长期显示在右侧的内容可以覆盖在整行
/// 尾部并相对整行纵向居中，标题和说明则为它预留出所需宽度。
struct SettingsRowLabel: View {
    let title: String
    let subtitle: String?
    var systemImage: String? = nil
    var iconColor: Color = .accentColor
    /// 覆盖在整行右侧、相对整行纵向居中的内容（当前值、计数等）。
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
        // 普通 Picker 的 label 不能再强制占满整行，否则系统当前值会被挤到下一行。
        // 只有行尾有覆盖内容（解析来源计数）时才需要撑满，才能把覆盖内容对齐到行尾。
        .frame(maxWidth: centeredTrailing == nil ? nil : .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if let centeredTrailing {
                centeredTrailing
            }
        }
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.trailing, centeredTrailingReserve)
    }
}

struct SettingsPickerOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// 原生菜单式 Picker 行。
///
/// 标题、说明和图标放在左侧，原生菜单 Picker 只负责右侧当前值与选项弹窗：
/// - 标题过长时在左侧换行，不会把当前值挤到下一行；
/// - 菜单仍由系统 `Picker` 弹出，锚定在行尾，选项对齐与选中标记保持原生行为。
struct SettingsPickerRow<Value: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var iconColor: Color = .accentColor
    @Binding var selection: Value
    let options: [SettingsPickerOption<Value>]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowLabel(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconColor: iconColor
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(selection: $selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.value)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            // 菜单式 Picker 的当前值由控件 tint 决定，foregroundStyle 改不到它；
            // 这里把 tint 设为主文字色，使当前值随深浅色显示为黑/白而不是强调蓝。
            .tint(Color.primary)
            // 先让系统 Picker 拿到它的理想宽度，剩余空间全部给左侧标题；
            // 这样超长标题只会自己换行，不会把当前值推到下一行。
            .fixedSize()
            .layoutPriority(1)
            .accessibilityLabel(Text(title))
        }
    }
}
