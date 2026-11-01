import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState


struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var localization = LocalizationManager.shared
    @ObservedObject var manager: DownloadManager
    @ObservedObject var registry = VideoSiteParserRegistry.shared

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        NavigationStack {
            Form {
                // 图标与名称是列表第一行，随内容一起滚动。
                // 用 listRowInsets/Background/Separator 把它伪装成"表头"。
                appHeader

                settingsSection
            }
            .navigationTitle(L("设置"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - App 图标 + 名称（可滚动）

    var appHeader: some View {
        VStack(spacing: 10) {
            appIconView

            Text(Self.appName)
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    var appIconView: some View {
        if let icon = Self.appIcon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        } else {
            // 还没有配置 AppIcon 时的占位
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 132, height: 132)
                .overlay {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }

    // MARK: - 设置项

    /// 所有设置项收在尽可能少的组里：下载与内容、外观与语言同属一组。
    /// 版本与作者信息不占行，放在这一组的页脚居中显示。
    var settingsSection: some View {
        Section {
            NavigationLink {
                DownloadSettingsView()
            } label: {
                Text(L("下载设置"))
            }

            NavigationLink {
                StorageSettingsView(manager: manager)
            } label: {
                Text(L("储存空间"))
            }

            NavigationLink {
                SiteSettingsView()
            } label: {
                LabeledContent(
                    L("解析来源"),
                    value: "\(enabledSiteCount)/\(registry.parsers.count)"
                )
            }

            NavigationLink {
                CookiesView()
            } label: {
                Text(L("Cookie 管理"))
            }

            NavigationLink {
                HistorySettingsView()
            } label: {
                Text(L("历史记录"))
            }

            NavigationLink {
                LogsView()
            } label: {
                Text(L("日志"))
            }

            NavigationLink {
                KeepAliveSettingsView(manager: manager)
            } label: {
                Text(L("后台保活"))
            }

            NavigationLink {
                LicensesView()
            } label: {
                Text(L("开源许可与致谢"))
            }

            Picker(L("外观"), selection: $appState.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .onChange(of: appState.appearanceMode) { _, _ in appState.persist() }

            Picker(L("语言"), selection: $localization.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            // Picker 的系统菜单会缓存选项文案。只重建这一行，既能刷新菜单，
            // 又不会像重建设置页那样把整个 Form 的滚动位置带回顶部。
            .id(localization.language)
        } footer: {
            versionFooter
        }
    }

    /// 页脚：居中显示版本与作者，形如「Nox v1.0.16 · Aholic」。
    ///
    /// 上下留出比默认稍大一点的间距，签名不会贴着上方分组、也不至于太局促。
    var versionFooter: some View {
        Text(verbatim: "\(Self.appName) v\(Self.appVersion) · Aholic")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.top, 12)
            .padding(.bottom, 12)
    }

    var enabledSiteCount: Int {
        registry.parsers.filter { appState.isSiteEnabled($0.identifier) }.count
    }

    // MARK: - Bundle 信息

    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Nox"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var appIcon: UIImage? {
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

/// 「开源许可与致谢」二级页：列出参考 / 复用来源，并附免责声明。
///
/// 说明：本页是「来源与致谢」而不是标准开源许可证列表 —— 参考的两个项目都没有
/// 标准许可证文件（只有署名要求），因此这里不写 SPDX 标识、也不冒充开源许可。
