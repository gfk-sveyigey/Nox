import SwiftUI
import NoxCore
import NoxState

struct InterfaceSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                SettingsPickerRow(
                    title: L("主题"),
                    selection: $appState.appearanceMode,
                    options: AppearanceMode.allCases.map {
                        SettingsPickerOption(value: $0, title: $0.title)
                    }
                )
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L("顶部安全区模糊强度"))
                        Spacer()
                        Text((1 - appState.browserSafeAreaTransparency).formatted(
                            .percent.precision(.fractionLength(0)).locale(AppLocale.current)
                        ))
                        .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { 1 - appState.browserSafeAreaTransparency },
                        set: { appState.browserSafeAreaTransparency = 1 - $0 }
                    ), in: 0...1, step: 0.01)
                        .accessibilityLabel(L("顶部安全区模糊强度"))
                    ZStack(alignment: .top) {
                        LinearGradient(colors: [.blue, .purple, .orange], startPoint: .leading, endPoint: .trailing)
                        BrowserFrostedBackdrop(safeAreaHeight: 32, addressBarHeight: 44,
                                                topStrength: 1 - appState.browserSafeAreaTransparency)
                    }
                    .frame(height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(L("透明度预览"))
                }
            } footer: {
                Text(L("模糊从顶部强度缓入至安全区中部的一半强度，再缓出至底部的 0%。"))
            }
        }
        .navigationTitle(L("界面设置"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appState.appearanceMode) { _, _ in appState.persist() }
        .onChange(of: appState.browserSafeAreaTransparency) { _, _ in appState.persist() }
    }
}
