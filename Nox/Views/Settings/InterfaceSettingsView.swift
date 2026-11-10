import SwiftUI
import NoxCore
import NoxState

struct InterfaceSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared

    private var supportsLiquidGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                SettingsPickerRow(
                    title: L("外观"),
                    selection: $appState.appearanceMode,
                    options: AppearanceMode.allCases.map {
                        SettingsPickerOption(value: $0, title: $0.title)
                    }
                )
            }
            Section {
                Toggle(L("启用液态玻璃效果"), isOn: Binding(
                    get: { supportsLiquidGlass && appState.liquidGlassEnabled },
                    set: { appState.liquidGlassEnabled = $0 }
                ))
                .disabled(!supportsLiquidGlass)
            } footer: {
                Text(L(supportsLiquidGlass
                    ? "仅影响应用自定义悬浮组件，系统标签栏和菜单仍由 iOS 控制。"
                    : "液态玻璃需要 iOS 26 或更高版本，当前使用兼容材质。"))
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L("顶部安全区透明度"))
                        Spacer()
                        Text(appState.browserSafeAreaTransparency.formatted(
                            .percent.precision(.fractionLength(0)).locale(AppLocale.current)
                        ))
                        .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $appState.browserSafeAreaTransparency, in: 0...1, step: 0.01)
                        .accessibilityLabel(L("顶部安全区透明度"))
                    ZStack(alignment: .top) {
                        LinearGradient(colors: [.blue, .purple, .orange], startPoint: .leading, endPoint: .trailing)
                        Rectangle().fill(.ultraThinMaterial)
                            .opacity(1 - appState.browserSafeAreaTransparency)
                            .frame(height: 40)
                    }
                    .frame(height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(L("透明度预览"))
                }
            } footer: {
                Text(L("数值越高越透明；仅调整浏览页顶部安全区，不改变网页位置。"))
            }
        }
        .navigationTitle(L("界面设置"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appState.appearanceMode) { _, _ in appState.persist() }
        .onChange(of: appState.liquidGlassEnabled) { _, _ in appState.persist() }
        .onChange(of: appState.browserSafeAreaTransparency) { _, _ in appState.persist() }
    }
}
