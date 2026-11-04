import SwiftUI
import UIKit

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

/// 同一页所有 picker 候选项的最大显示宽度，用于把右侧值的左边界对齐。
struct SettingsValueWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SettingsValueColumnWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var settingsValueColumnWidth: CGFloat {
        get { self[SettingsValueColumnWidthKey.self] }
        set { self[SettingsValueColumnWidthKey.self] = newValue }
    }
}

private struct SettingsValueColumnModifier: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.settingsValueColumnWidth, width)
            .onPreferenceChange(SettingsValueWidthPreferenceKey.self) { newWidth in
                // 上限避免超长语言把标题挤到无法阅读。
                let capped = min(max(newWidth, 0), 220)
                guard abs(capped - width) > 0.5 else { return }
                width = capped
            }
    }
}

extension View {
    /// 让同一页各 picker 的当前值在同一个左边界开始。
    func settingsValueColumn() -> some View {
        modifier(SettingsValueColumnModifier())
    }
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

    @Environment(\.settingsValueColumnWidth) private var valueColumnWidth

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? ""
    }

    /// 候选项里最长的一项决定本页值列的宽度，切换选项时列宽不会跳动。
    private var measuredValueWidth: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let textWidth = options.reduce(CGFloat.zero) { partial, option in
            let width = (option.title as NSString).size(withAttributes: [.font: font]).width
            return max(partial, width)
        }
        // 文本 + 4pt 间隔 + 上下箭头 + 少量余量。
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
        .frame(width: valueColumnWidth > 0 ? valueColumnWidth : nil, alignment: .leading)
    }

    var body: some View {
        Menu {
            // 用系统 Picker 渲染菜单项：选中项的对勾由系统统一排版，
            // 所有选项的文字左端保持在同一列。
            Picker(selection: $selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.value)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            SettingsRowLabel(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconColor: iconColor,
                trailing: AnyView(valueView)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .preference(key: SettingsValueWidthPreferenceKey.self, value: measuredValueWidth)
    }
}
