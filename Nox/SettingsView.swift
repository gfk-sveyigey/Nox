import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        NavigationStack {
            Form {
                // 图标与名称现在是列表里的第一行，随内容一起滚动。
                // 用 listRowInsets/Background/Separator 把它伪装成"表头"。
                appHeader

                qualitySection
                sitesLinkSection
                languageSection
                experimentalSection
                aboutSection
            }
            .navigationTitle(String(localized: "设置"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - App 图标 + 名称（可滚动）

    private var appHeader: some View {
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
    private var appIconView: some View {
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

    // MARK: - 下载

    private var qualitySection: some View {
        Section {
            Picker(String(localized: "下载清晰度"), selection: $appState.preferredQuality) {
                ForEach(PreferredQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .onChange(of: appState.preferredQuality) { _, _ in
                appState.persist()
            }
        }
    }

    // MARK: - 视频站点（二级页入口）

    private var sitesLinkSection: some View {
        Section {
            NavigationLink {
                SiteSettingsView()
            } label: {
                LabeledContent(
                    String(localized: "视频站点"),
                    value: "\(enabledSiteCount)/\(VideoSiteParserRegistry.all.count)"
                )
            }
        }
    }

    private var enabledSiteCount: Int {
        VideoSiteParserRegistry.all.filter { appState.isSiteEnabled($0.identifier) }.count
    }

    // MARK: - 语言

    private var languageSection: some View {
        Section {
            Picker(String(localized: "语言"), selection: $localization.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
        } header: {
            Text("语言")
        } footer: {
            Text("选择 App 的显示语言。选择「跟随系统」时，App 会与系统语言保持一致。")
        }
    }

    // MARK: - 实验性功能

    private var experimentalSection: some View {
        Section {
            Toggle(String(localized: "多线程下载"), isOn: $appState.experimentalMultiThreadDownload)
                .onChange(of: appState.experimentalMultiThreadDownload) { _, _ in
                    appState.persist()
                }

            if appState.experimentalMultiThreadDownload {
                Picker(String(localized: "下载线程数"), selection: $appState.multiThreadSegmentCount) {
                    ForEach(Array(AppState.segmentCountRange), id: \.self) { count in
                        Text(String(count)).tag(count)
                    }
                }
                .onChange(of: appState.multiThreadSegmentCount) { _, _ in
                    appState.persist()
                }
            }
        } header: {
            Text("实验性功能")
        } footer: {
            Text("把文件分成多个分片并行下载，可能提升速度。部分站点会限速或拒绝多连接，若出现下载失败请关闭此项。已开始的任务需要重试后才会按新设置重新分片。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent(String(localized: "版本"), value: Self.appVersion)
        } header: {
            Text("关于")
        }
    }

    // MARK: - Bundle 信息

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Nox"
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private static var appIcon: UIImage? {
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

/// 视频站点开关的二级页。
///
/// 站点数量增长后，这里会自动变长，不用改设置主页的结构。
struct SiteSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                ForEach(siteToggles) { site in
                    Toggle(site.title, isOn: siteBinding(for: site.id))
                }
            } footer: {
                Text("关闭后，对应网站的页面将无法解析，「解析视频」按钮也会置灰。")
            }
        }
        .navigationTitle(String(localized: "视频站点"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func siteBinding(for identifier: String) -> Binding<Bool> {
        Binding(
            get: { appState.isSiteEnabled(identifier) },
            set: { appState.setSite(identifier, enabled: $0) }
        )
    }

    /// 把解析器列表转成可 `ForEach` 的简单结构，
    /// 避免对 `any VideoSiteParser` 取 key path。
    private var siteToggles: [SiteToggle] {
        VideoSiteParserRegistry.all.map {
            SiteToggle(id: $0.identifier, title: $0.displayName)
        }
    }

    private struct SiteToggle: Identifiable {
        let id: String
        let title: String
    }
}