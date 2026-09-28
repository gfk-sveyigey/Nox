import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    private let qualities = ["Best", "1080", "720", "480", "360"]

    var body: some View {
        NavigationStack {
            Form {
                Section("下载") {
                    Picker("默认清晰度", selection: $appState.preferredQuality) {
                        ForEach(qualities, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: appState.preferredQuality) { _, _ in appState.persist() }
                }
                Section("历史") {
                    Toggle("启动时清空历史", isOn: $appState.clearHistoryOnLaunch)
                        .onChange(of: appState.clearHistoryOnLaunch) { _, _ in appState.persist() }
                }
                Section("存储") {
                    HStack {
                        Text("下载目录")
                        Spacer()
                        Text("App/Documents")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("VideoSaver")
                    Text("仅用于下载你有权访问和保存的内容。不会实现 DRM、付费墙或登录绕过。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}
