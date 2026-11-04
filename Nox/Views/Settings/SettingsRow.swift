import SwiftUI

/// 设置行左侧的图标 + 标题 + 说明。
///
/// 标题和说明都允许纵向换行。右侧当前值或附加信息放在标题同一行，
/// 说明独占下方整行，这样所有条目的说明右边界保持一致，
/// 不会被不同长度的当前值挤得忽宽忽窄。
struct SettingsRowLabel: View {
    let title: String
    let subtitle: String?
    var systemImage: String? = nil
    var iconColor: Color = .accentColor
    /// 标题行右侧的附加内容（当前值、计数等）。
    var trailing: AnyView? = nil

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
        .frame(minHeight: 40)
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
    }
}

struct SettingsPickerOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// 带右侧当前值的设置行。
///
/// 左侧标题/说明负责换行，右侧值固定单行并优先获得宽度，
/// 避免长语言下当前值被挤到下一行。
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

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            SettingsRowLabel(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconColor: iconColor,
                trailing: AnyView(
                    HStack(spacing: 4) {
                        Text(selectedTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
