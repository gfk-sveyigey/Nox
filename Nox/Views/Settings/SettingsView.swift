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
                settingsSections
            }
            .navigationTitle(L("设置"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 设置项

    /// 设置项按用途分成四组，但不显示分组标题，只用间距做视觉分割。
    @ViewBuilder
    var settingsSections: some View {
        Section {
            settingsLink(
                L("推送通知"),
                subtitle: L("设置中断提醒、完成提醒和任务名显示。"),
                systemImage: "bell.badge",
                iconColor: .red
            ) {
                NotificationSettingsView(manager: manager)
            }

            settingsLink(
                L("下载设置"),
                subtitle: L("调整同时任务数、下载网络和线程等选项。"),
                systemImage: "arrow.down.circle",
                iconColor: .blue
            ) {
                DownloadSettingsView(manager: manager)
            }

            settingsLink(
                L("后台下载"),
                subtitle: L("配置后台运行方式与保活策略。"),
                systemImage: "play.circle",
                iconColor: .green
            ) {
                KeepAliveSettingsView(manager: manager)
            }

            settingsLink(
                L("储存空间"),
                subtitle: L("查看储存占用，并清理缓存和临时文件。"),
                systemImage: "internaldrive",
                iconColor: .orange
            ) {
                StorageSettingsView(manager: manager)
            }
        }

        Section {
            NavigationLink {
                SiteSettingsView()
            } label: {
                HStack(spacing: 8) {
                    settingsLabel(
                        L("解析来源"),
                        subtitle: L("管理站点解析插件和匹配顺序。"),
                        systemImage: "puzzlepiece.extension",
                        iconColor: .purple
                    )
                    Spacer(minLength: 8)
                    Text("\(enabledSiteCount)/\(registry.parsers.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            settingsLink(
                L("Cookie 管理"),
                subtitle: L("查看并清理各网站保存的 Cookie。"),
                systemImage: "shield",
                iconColor: .teal
            ) {
                CookiesView()
            }

            settingsLink(
                L("历史记录"),
                subtitle: L("设置历史保留方式，并清理访问记录。"),
                systemImage: "clock.arrow.circlepath",
                iconColor: .indigo
            ) {
                HistorySettingsView()
            }

            settingsLink(
                L("日志"),
                subtitle: L("查看运行日志，帮助定位问题。"),
                systemImage: "doc.text",
                iconColor: .brown
            ) {
                LogsView()
            }
        }

        Section {
            Picker(selection: $appState.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                settingsLabel(
                    L("外观"),
                    subtitle: L("选择跟随系统、浅色或深色外观。"),
                    systemImage: "circle.lefthalf.filled",
                    iconColor: .pink
                )
            }
            .onChange(of: appState.appearanceMode) { _, _ in appState.persist() }
            // 系统 Picker 菜单会缓存选项文案；切语言后重建这一行即可刷新。
            .id(localization.language)

            Picker(selection: $localization.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            } label: {
                settingsLabel(
                    L("语言"),
                    subtitle: L("更改应用界面语言。"),
                    systemImage: "globe",
                    iconColor: .cyan
                )
            }
            // Picker 的系统菜单会缓存选项文案。只重建这一行，既能刷新菜单，
            // 又不会像重建设置页那样把整个 Form 的滚动位置带回顶部。
            .id(localization.language)
        }

        Section {
            settingsLink(
                L("开源许可与致谢"),
                subtitle: L("查看第三方项目、许可信息与致谢。"),
                systemImage: "heart.text.square",
                iconColor: .red
            ) {
                LicensesView()
            }
        } footer: {
            versionFooter
        }
    }

    /// 统一设置条目：图标 + 标题 + 一行说明，并适当增加行高。
    func settingsLink<Destination: View>(
        _ title: String,
        subtitle: String,
        systemImage: String,
        iconColor: Color,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            settingsLabel(
                title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconColor: iconColor
            )
        }
    }

    func settingsLabel(
        _ title: String,
        subtitle: String,
        systemImage: String,
        iconColor: Color
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)
                .frame(width: 24, alignment: .center)
        }
        .frame(minHeight: 40)
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

}

/// 「开源许可与致谢」二级页：列出参考 / 复用来源，并附免责声明。
///
/// 说明：本页是「来源与致谢」而不是标准开源许可证列表 —— 参考的两个项目都没有
/// 标准许可证文件（只有署名要求），因此这里不写 SPDX 标识、也不冒充开源许可。
