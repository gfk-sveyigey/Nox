import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    private let qualities = ["每次询问", "最佳", "1080", "720", "480", "360"]

    var body: some View {
        NavigationStack {
            Form {
                Section("下载") {
                    Picker("下载清晰度", selection: $appState.preferredQuality) {
                        ForEach(qualities, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .onChange(of: appState.preferredQuality) { _, _ in
                        appState.persist()
                    }
                }

                Section("历史") {
                    Toggle("启动时清空历史", isOn: $appState.clearHistoryOnLaunch)
                        .onChange(of: appState.clearHistoryOnLaunch) { _, _ in
                            appState.persist()
                        }
                }

                Section("关于") {
                    LabeledContent(
                        "版本",
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                    )

                    Text("VideoSaver")

                    Text("下载文件保存在本 App 的 Documents 文件夹中，可通过 iOS 文件 App 访问。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
