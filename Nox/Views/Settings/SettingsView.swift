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
    let scrollToTopToken: Int

    init(manager: DownloadManager, scrollToTopToken: Int = 0) {
        self.scrollToTopToken = scrollToTopToken
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        NavigationStack {
            Form {
                settingsSections
            }
            .contentMargins(.top, 20, for: .scrollContent)
            .background(ScrollToPhysicalTop(token: scrollToTopToken))
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
            .id("settings-first-row")

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
            Toggle(L("请求桌面版网站"), isOn: $appState.browserDesktopMode)
                .onChange(of: appState.browserDesktopMode) { _, _ in appState.persist() }
            Text(L("关闭时使用移动版 UA，切换后会重新加载当前网页。"))
                .font(.footnote).foregroundStyle(.secondary)
            NavigationLink {
                SiteSettingsView()
            } label: {
                SettingsRowLabel(
                    title: L("解析来源"),
                    subtitle: L("管理站点解析插件和匹配顺序。"),
                    systemImage: "puzzlepiece.extension",
                    iconColor: .purple,
                    centeredTrailing: AnyView(
                        Text(siteCountText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    ),
                    centeredTrailingReserve: siteCountWidth
                )
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
                L("日志"),
                subtitle: L("查看运行日志，帮助定位问题。"),
                systemImage: "doc.text",
                iconColor: .brown
            ) {
                LogsView()
            }
        }

        Section {
            settingsLink(
                L("界面设置"),
                subtitle: L("调整外观和浏览界面透明度。"),
                systemImage: "paintpalette",
                iconColor: .pink
            ) {
                InterfaceSettingsView()
            }

            SettingsPickerRow(
                title: L("语言"),
                subtitle: L("更改应用界面语言。"),
                systemImage: "globe",
                iconColor: .cyan,
                selection: $localization.language,
                options: AppLanguage.allCases.map {
                    SettingsPickerOption(value: $0, title: $0.title)
                }
            )
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
            SettingsRowLabel(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconColor: iconColor
            )
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

    var siteCountText: String {
        "\(enabledSiteCount)/\(registry.parsers.count)"
    }

    /// 计数使用等宽数字，这里按同一字体测量，避免预留宽度不足。
    var siteCountWidth: CGFloat {
        let pointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        let font = UIFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .regular)
        let width = (siteCountText as NSString).size(withAttributes: [.font: font]).width
        return ceil(width) + 10
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
