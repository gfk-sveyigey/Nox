import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var manager: DownloadManager

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

    // MARK: - 设置项

    /// 所有设置项都是「单行」，所以放在同一个分组里，不再逐条套一层分组卡片。
    private var settingsSection: some View {
        Section {
            NavigationLink {
                DownloadSettingsView()
            } label: {
                Text(L("下载设置"))
            }

            NavigationLink {
                SiteSettingsView()
            } label: {
                LabeledContent(
                    L("解析来源"),
                    value: "\(enabledSiteCount)/\(VideoSiteParserRegistry.all.count)"
                )
            }

            Picker(L("语言"), selection: $localization.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }

            NavigationLink {
                StorageSettingsView(manager: manager)
            } label: {
                Text(L("储存空间"))
            }

            LabeledContent(L("版本"), value: "v\(Self.appVersion)")
        } footer: {
            Text(L("选择 App 的显示语言。选择「跟随系统」时，App 会与系统语言保持一致。"))
        }
    }

    private var enabledSiteCount: Int {
        VideoSiteParserRegistry.all.filter { appState.isSiteEnabled($0.identifier) }.count
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

/// 「下载设置」二级页：同时下载任务数、下载清晰度，以及多线程（分片）相关的开关。
struct DownloadSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                Picker(L("同时下载任务数"), selection: $appState.maxConcurrentDownloads) {
                    ForEach(AppState.maxConcurrentDownloadsOptions, id: \.self) { count in
                        Text(Self.concurrentTitle(count)).tag(count)
                    }
                }
                .onChange(of: appState.maxConcurrentDownloads) { _, _ in
                    appState.persist()
                }

                Picker(L("下载清晰度"), selection: $appState.preferredQuality) {
                    ForEach(PreferredQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .onChange(of: appState.preferredQuality) { _, _ in
                    appState.persist()
                }
            }

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
            } footer: {
                Text(L("把文件分成多个分片并行下载，可能提升速度。部分站点会限速或拒绝多连接，若出现下载失败请关闭此项。已开始的任务需要重试后才会按新设置重新分片。"))
            }
        }
        .navigationTitle(L("下载设置"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func concurrentTitle(_ count: Int) -> String {
        count == AppState.unlimitedConcurrentDownloads ? L("无限制") : String(count)
    }
}

/// 「解析来源」开关的二级页（各视频站点 + Sniffer）。
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
                Text(L("关闭后，对应网站的页面将无法解析，「解析视频」入口也会隐藏。"))
            }
        }
        .navigationTitle(L("解析来源"))
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

/// 「储存空间」里可单独统计与清理的类别。
enum StorageCategory: String, CaseIterable, Identifiable {
    case videos
    case parts
    case staging
    case networkCache
    case websiteData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: return L("已下载视频")
        case .parts: return L("下载分片")
        case .staging: return L("临时文件")
        case .networkCache: return L("网络缓存")
        case .websiteData: return L("网站数据")
        }
    }

    var systemImage: String {
        switch self {
        case .videos: return "film"
        case .parts: return "square.split.2x2"
        case .staging: return "folder"
        case .networkCache: return "network"
        case .websiteData: return "globe"
        }
    }
}

/// 「储存空间」二级页：按类别展示占用，勾选任意几类后清理。
struct StorageSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var manager: DownloadManager

    @State private var sizes: [StorageCategory: Int64] = [:]
    @State private var selection = Set<StorageCategory>()
    @State private var showingClearConfirmation = false

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        List {
            Section {
                ForEach(StorageCategory.allCases) { category in
                    Button {
                        toggle(category)
                    } label: {
                        row(for: category)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(L("储存空间"))
            } footer: {
                Text(L("点选要清理的类别，再点下方「清理所选」。清理网站数据会退出已登录的网站。"))
            }

            Section {
                LabeledContent(L("合计"), value: TransferStats.formattedSize(totalSize))
            }

            Section {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Text(L("清理所选"))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(selection.isEmpty)
            }
        }
        .navigationTitle(L("储存空间"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 右上角：重新统计各项占用
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L("刷新"))
            }
        }
        .task { refresh() }
        .onChange(of: appState.downloads.count) { _, _ in refresh() }
        .alert(L("清理所选？"), isPresented: $showingClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清理"), role: .destructive) {
                clearSelected()
            }
        } message: {
            Text(L("所选类别的缓存与文件将被删除，此操作无法撤销。"))
        }
    }

    private func row(for category: StorageCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 26)

            Text(category.title)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Text(TransferStats.formattedSize(sizes[category] ?? 0))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Image(systemName: selection.contains(category) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selection.contains(category)
                                 ? Color.accentColor
                                 : Color.secondary.opacity(0.35))
        }
    }

    private var totalSize: Int64 {
        sizes.values.reduce(0, +)
    }

    private func toggle(_ category: StorageCategory) {
        if selection.contains(category) {
            selection.remove(category)
        } else {
            selection.insert(category)
        }
    }

    private func refresh() {
        sizes = [
            .videos: manager.documentsSize(),
            .parts: manager.partsSize(),
            .staging: manager.stagingSize(),
            .networkCache: manager.networkCacheSize(),
            .websiteData: manager.websiteDataSize()
        ]
    }

    private func clearSelected() {
        let categories = selection
        selection.removeAll()

        Task {
            if categories.contains(.videos) {
                // 只删已完成的成品；正在下载的任务交给分片清理，避免打断下载
                let finishedIDs = Set(
                    appState.downloads.filter { $0.status == .finished }.map(\.id)
                )
                manager.deleteFiles(ids: finishedIDs)
            }

            if categories.contains(.parts) { manager.clearParts() }
            if categories.contains(.staging) { manager.clearStaging() }
            if categories.contains(.networkCache) { manager.clearNetworkCache() }
            if categories.contains(.websiteData) { await manager.clearWebsiteData() }

            refresh()
        }
    }
}
