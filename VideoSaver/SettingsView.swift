import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    private let qualities = ["每次询问", "最佳", "1080", "720", "480", "360"]

    var body: some View {
        NavigationStack {
            Form {
                appHeader

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

                Section {
                    Toggle("多线程下载", isOn: $appState.experimentalMultiThreadDownload)
                        .onChange(of: appState.experimentalMultiThreadDownload) { _, _ in
                            appState.persist()
                        }
                } header: {
                    Text("实验性功能")
                } footer: {
                    Text("把文件分成 4 段并行下载，可能提升速度。部分站点会限速或拒绝多连接，若出现下载失败请关闭此项。已开始的任务需要重试后才会按新设置重新分片。")
                }

                Section("历史") {
                    Toggle("启动时清空历史", isOn: $appState.clearHistoryOnLaunch)
                        .onChange(of: appState.clearHistoryOnLaunch) { _, _ in
                            appState.persist()
                        }
                }

                Section("关于") {
                    LabeledContent("版本", value: Self.appVersion)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 顶部 App 图标 + 名称

    private var appHeader: some View {
        VStack(spacing: 12) {
            appIconView

            Text(Self.appName)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder
    private var appIconView: some View {
        if let icon = Self.appIcon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        } else {
            // 还没有配置 AppIcon 时的占位
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 84, height: 84)
                .overlay {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }

    // MARK: - Bundle 信息

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "VideoSaver"
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private static var appIcon: UIImage? {
        // asset catalog 里另建了 AppIconPreview 普通 image set，读取最可靠
        if let image = UIImage(named: "AppIconPreview") {
            return image
        }

        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last,
           let image = UIImage(named: name) {
            return image
        }

        return UIImage(named: "AppIcon")
    }
}