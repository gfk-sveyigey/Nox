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
                    title: L("外观"),
                    selection: $appState.appearanceMode,
                    options: AppearanceMode.allCases.map {
                        SettingsPickerOption(value: $0, title: $0.title)
                    }
                )
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
                            .mask {
                                LinearGradient(
                                    colors: [.black.opacity(max(0.8, 1 - appState.browserSafeAreaTransparency)),
                                             .black.opacity(1 - appState.browserSafeAreaTransparency)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            }
                            .frame(height: 40)
                    }
                    .frame(height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(L("透明度预览"))
                }
            } footer: {
                Text(L("数值越高越透明；同时调整地址栏和安全区下沿，安全区顶端保留模糊。"))
            }
        }
        .navigationTitle(L("界面设置"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appState.appearanceMode) { _, _ in appState.persist() }
        .onChange(of: appState.browserSafeAreaTransparency) { _, _ in appState.persist() }
    }
}
