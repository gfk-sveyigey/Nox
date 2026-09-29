import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var manager: DownloadManager

    @State private var cacheBytes: Int64 = 0
    @State private var showingCacheClearConfirmation = false

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        NavigationStack {
            Form {
                // 图标与名称是列表第一行，随内容一起滚动。
                // 用 listRowInsets/Background/Separator 把它伪装成"表头"。
                appHeader

                qualitySection
                sitesLinkSection
                languageSection
                experimentalSection
                storageSection
                aboutSection
            }
            .navigationTitle(L("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                refreshCacheSize()
            }
            .alert(L("清空缓存？"), isPresented: $showingCacheClearConfirmation) {
                Button(L("取消"), role: .cancel) {}
                Button(L("清空"), role: .destructive) {
                    manager.clearCache()
                    refreshCacheSize()
                }
            } message: {
                Text(L("将删除未完成下载的分片与临时文件。正在下载的任务不受影响，已下载的视频也不会被删除。"))
            }
        }
    }

    private func refreshCacheSize() {
        cacheBytes = manager.cacheSize()
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
            Picker(L("下载清晰度"), selection: $appState.preferredQuality) {
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
                    L("视频站点"),
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
            Picker(L("语言"), selection: $localization.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
        } header: {
            Text(L("语言"))
        } footer: {
            Text(L("选择 App 的显示语言。选择「跟随系统」时，App 会与系统语言保持一致。"))
        }
    }

    // MARK: - 实验性功能

    private var experimentalSection: some View {
        Section {
            Toggle(L("多线程下载"), isOn: $appState.experimentalMultiThreadDownload)
                .onChange(of: appState.experimentalMultiThreadDownload) { _, _ in
                    appState.persist()
                }

            if appState.experimentalMultiThreadDownload {
                Picker(L("下载线程数"), selection: $appState.multiThreadSegmentCount) {
                    ForEach(Array(AppState.segmentCountRange), id: \.self) { count in
                        Text(String(count)).tag(count)
                    }
                }
                .onChange(of: appState.multiThreadSegmentCount) { _, _ in
                    appState.persist()
                }
            }

            Picker(L("同时下载任务数"), selection: $appState.maxConcurrentDownloads) {
                ForEach(Array(AppState.maxConcurrentDownloadsRange), id: \.self) { count in
                    Text(String(count)).tag(count)
                }
            }
            .onChange(of: appState.maxConcurrentDownloads) { _, _ in
                appState.persist()
            }

            Picker(L("m3u8 分片并发"), selection: $appState.m3u8SegmentConcurrency) {
                Text(L("跟随多线程设置")).tag(0)

                ForEach(Array(AppState.m3u8ConcurrencyRange), id: \.self) { count in
                    if count > 0 {
                        Text(String(count)).tag(count)
                    }
                }
            }
            .onChange(of: appState.m3u8SegmentConcurrency) { _, _ in
                appState.persist()
            }
        } header: {
            Text(L("实验性功能"))
        } footer: {
            Text(L("把文件分成多个分片并行下载，可能提升速度。部分站点会限速或拒绝多连接，若出现下载失败请关闭此项。已开始的任务需要重试后才会按新设置重新分片。"))
        }
    }

    // MARK: - 存储（缓存）

    private var storageSection: some View {
        Section {
            LabeledContent(L("已用缓存"), value: TransferStats.formattedSize(cacheBytes))

            Button(role: .destructive) {
                showingCacheClearConfirmation = true
            } label: {
                Text(L("清空缓存"))
            }
            .disabled(cacheBytes == 0)
        } header: {
            Text(L("存储"))
        } footer: {
            Text(L("缓存是未完成下载的分片与临时文件。清空不会删除已下载的视频；正在下载的任务会被跳过。"))
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent(L("版本"), value: Self.appVersion)
        } header: {
            Text(L("关于"))
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
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                ForEach(siteToggles) { site in
                    Toggle(site.title, isOn: siteBinding(for: site.id))
                }
            } footer: {
                Text(L("关闭后，对应网站的页面将无法解析，「解析视频」按钮也会置灰。"))
            }
        }
        .navigationTitle(L("视频站点"))
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