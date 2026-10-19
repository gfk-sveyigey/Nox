import SwiftUI
import UIKit
import WebKit

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

    /// 所有设置项收在尽可能少的组里：下载与内容、外观与语言同属一组。
    /// 版本与作者信息不占行，放在这一组的页脚居中显示。
    private var settingsSection: some View {
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
                    value: "\(enabledSiteCount)/\(VideoSiteParserRegistry.all.count)"
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
        } footer: {
            versionFooter
        }
    }

    /// 页脚：居中显示版本与作者，形如「Nox v1.0.16 · Aholic」。
    ///
    /// 上下留出比默认稍大一点的间距，签名不会贴着上方分组、也不至于太局促。
    private var versionFooter: some View {
        Text(verbatim: "\(Self.appName) v\(Self.appVersion) · Aholic")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.top, 12)
            .padding(.bottom, 12)
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

/// 「开源许可与致谢」二级页：列出参考 / 复用来源，并附免责声明。
///
/// 说明：本页是「来源与致谢」而不是标准开源许可证列表 —— 参考的两个项目都没有
/// 标准许可证文件（只有署名要求），因此这里不写 SPDX 标识、也不冒充开源许可。
struct LicensesView: View {
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                creditRow(
                    name: "PiP",
                    author: "CaiWanFeng",
                    detail: L("原始画中画示例"),
                    urlString: "https://github.com/CaiWanFeng/PiP"
                )

                creditRow(
                    name: "GlobalRefresh-PiP",
                    author: "Yoroin",
                    detail: L("后台保活与画中画共存保护参考实现"),
                    urlString: "https://github.com/Yoroin/GlobalRefresh-PiP"
                )
            } header: {
                Text(L("来源与致谢"))
            } footer: {
                Text(L("本项目在其基础上实现后台保活与画中画共存保护，保留原作者的署名与项目地址；本项目与上述项目无隶属关系。"))
            }

            Section {
                Text(L("本项目仅供学习与个人测试使用。使用者在安装、签名和使用过程中需自行承担风险，请勿用于违反平台规则、商业侵权或其他不当用途。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("免责声明"))
            }
        }
        .navigationTitle(L("开源许可与致谢"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 一条来源：名称、作者、用途说明与仓库链接（整行可点开仓库）。
    private func creditRow(name: String, author: String, detail: String, urlString: String) -> some View {
        Link(destination: URL(string: urlString)!) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name)
                    .foregroundStyle(.primary)

                Text(String(format: L("作者：%@"), author))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(verbatim: urlString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

/// 「后台保活」二级页：选择保活方式、保活模式、画中画窗口大小与共存兜底。
struct KeepAliveSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var manager: DownloadManager

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        Form {
            Section {
                Picker(L("保活方式"), selection: Binding(
                    get: { appState.keepAliveMode },
                    set: { manager.setKeepAliveMode($0) }
                )) {
                    ForEach(KeepAliveMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                // 只有画中画才有悬浮窗，其它保活方式下这个滑块没有意义。
                if appState.keepAliveMode == .pictureInPicture {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("画中画窗口大小"))
                            Spacer()
                            Text(pipWindowSizeTitle)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: Binding(
                                get: { appState.pipWindowHeight },
                                set: { manager.setPiPWindowHeight($0) }
                            ),
                            in: AppState.pipWindowHeightRange,
                            step: 1
                        )
                    }
                }
            } footer: {
                if appState.keepAliveMode == .pictureInPicture {
                    Text(L("拖动到最左即最小：窗口高 0.1pt，视觉隐藏、不影响操作；越往右窗口越大。"))
                }
            }

            // 保活方式为「关闭」时不需要选生命周期。
            if appState.keepAliveMode != .off {
                Section {
                    Picker(L("保活模式"), selection: Binding(
                        get: { appState.keepAliveLifetime },
                        set: { manager.setKeepAliveLifetime($0) }
                    )) {
                        ForEach(KeepAliveLifetime.allCases) { lifetime in
                            Text(lifetime.title).tag(lifetime)
                        }
                    }
                } footer: {
                    Text(L("跟随下载任务：有下载任务时才保活。启动即常驻：进入前台即拉起并一直保持，直到把保活方式设为「关闭」。"))
                }
            }

            // 只有画中画需要共存保护；选了其它保活方式时这一组整段隐藏。
            if appState.keepAliveMode == .pictureInPicture {
                Section {
                    Picker(L("共存保护不可用时"), selection: Binding(
                        get: { appState.pipCoexistenceFallback },
                        set: { manager.setPiPCoexistenceFallback($0) }
                    )) {
                        ForEach(PiPCoexistenceFallback.allCases) { fallback in
                            Text(fallback.title).tag(fallback)
                        }
                    }
                } footer: {
                    Text(L("画中画可能与其他 App 的画中画互相打断。这里选择共存保护不可用时如何处理。"))
                }
            }

            // 详细日志只影响画中画保活的诊断输出，不改变保活行为。
            if appState.keepAliveMode == .pictureInPicture {
                Section {
                    Toggle(isOn: Binding(
                        get: { appState.pipVerboseLogging },
                        set: { manager.setPiPVerboseLogging($0) }
                    )) {
                        Text(L("详细日志"))
                    }
                } footer: {
                    Text(L("开启后记录画中画启动、就绪判断、重试及系统回调等诊断信息，日志量会明显增加；排查完成后建议关闭。"))
                }
            }
        }
        .navigationTitle(L("后台保活"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 滑块当前值说明：最左为「最小」（隐藏），其余显示高度点数。
    private var pipWindowSizeTitle: String {
        appState.pipWindowHeight < 1 ? L("最小") : "\(Int(appState.pipWindowHeight.rounded())) pt"
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

/// 「储存空间」二级页：按类别展示占用。
///
/// 多选逻辑与「下载 / 历史」页保持一致：双指滑动进入多选，
/// 并沿滑动路径勾选类别，最后由右上角的「清理」统一清理。
struct StorageSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var manager: DownloadManager

    @State private var sizes: [StorageCategory: Int64] = [:]
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<StorageCategory>()
    @State private var rowFrames: [StorageCategory: CGRect] = [:]
    @State private var showingClearConfirmation = false
    @State private var isVisible = false

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        List(selection: listSelection) {
            Section {
                ForEach(StorageCategory.allCases) { category in
                    row(for: category)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: StorageRowFrameKey.self,
                                    value: [category: proxy.frame(in: .global)]
                                )
                            }
                        }
                        .tag(category)
                }
            } header: {
                Text(L("储存空间"))
            } footer: {
                Text(L("双指下滑进入多选，勾选要清理的类别，再点右上角「清理」。清理网站数据会退出已登录的网站。"))
            }

            Section {
                LabeledContent(L("合计"), value: TransferStats.formattedSize(totalSize))
            }
        }
        .environment(\.editMode, $editMode)
        .onPreferenceChange(StorageRowFrameKey.self) { rowFrames = $0 }
        .navigationBarBackButtonHidden(editMode.isEditing)
        .navigationTitle(L("储存空间"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: editMode) { _, newValue in
            if !newValue.isEditing { selection.removeAll() }
        }
        .task { refresh() }
        .onChange(of: appState.downloads.count) { _, _ in refresh() }
        // 与下载 / 历史页一致：双指滑动进入多选，并按路径选中类别。
        .twoFingerPanToSelect(
            isEnabled: isVisible,
            onBegin: { beginTwoFingerSelection() },
            onPath: { selectRows(in: $0) }
        )
        .alert(L("清理所选？"), isPresented: $showingClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清理"), role: .destructive) { clearSelected() }
        } message: {
            Text(L("所选类别的缓存与文件将被删除，此操作无法撤销。"))
        }
    }

    /// 双指滑动开始时进入多选；已经在多选态时不重复触发动画。
    private func beginTwoFingerSelection() {
        guard !editMode.isEditing else { return }
        withAnimation { editMode = .active }
    }

    /// 把双指滑过的路径映射到可见类别；只增选，不反转已选项。
    private func selectRows(in path: CGRect) {
        let categories = rowFrames.compactMap { category, frame in
            frame.intersects(path) ? category : nil
        }
        guard !categories.isEmpty else { return }
        selection.formUnion(categories)
    }

    /// 清理完成后退出多选，避免停留在不可继续操作的选择状态。
    private func finishSelection() {
        selection.removeAll()
        guard editMode.isEditing else { return }
        withAnimation { editMode = .inactive }
    }

    /// 多选态才把选择绑给列表（与下载 / 历史页相同的处理）。
    private var listSelection: Binding<Set<StorageCategory>> {
        Binding(
            get: { editMode.isEditing ? selection : [] },
            set: { newValue in
                guard editMode.isEditing else { return }
                selection = newValue
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 多选只通过双指滑动进入；进入后在返回键的位置显示「完成」。
        ToolbarItem(placement: .topBarLeading) {
            if editMode.isEditing {
                Button(L("完成")) {
                    withAnimation { editMode = .inactive }
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if editMode.isEditing {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Text(L("清理"))
                        .foregroundStyle(.red)
                }
                .disabled(selection.isEmpty)
            } else {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L("刷新"))
            }
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
        }
        .contentShape(Rectangle())
    }

    private var totalSize: Int64 {
        sizes.values.reduce(0, +)
    }

    private func refresh() {
        sizes = [
            .videos: manager.videosSize(),
            .parts: manager.partsSize(),
            .staging: manager.stagingSize(),
            .networkCache: manager.networkCacheSize(),
            .websiteData: manager.websiteDataSize()
        ]
    }

    private func clearSelected() {
        let categories = selection
        finishSelection()

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

            LogStore.shared.info("storage cleared: " + categories.map(\.rawValue).sorted().joined(separator: ","))

            refresh()
        }
    }
}

/// 收集可见储存类别行的全局坐标，供双指路径选择使用。
private struct StorageRowFrameKey: PreferenceKey {
    static let defaultValue: [StorageCategory: CGRect] = [:]

    static func reduce(
        value: inout [StorageCategory: CGRect],
        nextValue: () -> [StorageCategory: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 「历史记录」二级页：保留方式（按条数 / 按时间）与具体数值。
struct HistorySettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                Picker(L("保留方式"), selection: $appState.historyRetentionMode) {
                    ForEach(HistoryRetentionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: appState.historyRetentionMode) { _, _ in
                    appState.applyHistoryRetention()
                    appState.persist()
                }

                switch appState.historyRetentionMode {
                case .count:
                    Picker(L("最大条数"), selection: $appState.historyRetentionCount) {
                        ForEach(AppState.historyCountOptions, id: \.self) { value in
                            Text(historyCountTitle(value)).tag(value)
                        }
                    }
                    .onChange(of: appState.historyRetentionCount) { _, _ in
                        appState.applyHistoryRetention()
                        appState.persist()
                    }
                case .days:
                    Picker(L("最多保留天数"), selection: $appState.historyRetentionDays) {
                        ForEach(AppState.historyDayOptions, id: \.self) { value in
                            Text(historyDayTitle(value)).tag(value)
                        }
                    }
                    .onChange(of: appState.historyRetentionDays) { _, _ in
                        appState.applyHistoryRetention()
                        appState.persist()
                    }
                }
            } footer: {
                Text(L("超出保留范围的历史记录会被自动删除。"))
            }

            Section {
                LabeledContent(L("当前记录"), value: String(appState.history.count))
            }
        }
        .navigationTitle(L("历史记录"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func historyCountTitle(_ value: Int) -> String {
        value == AppState.unlimitedHistory ? L("无限制") : String(value)
    }

    private func historyDayTitle(_ value: Int) -> String {
        value == AppState.unlimitedHistory ? L("无限制") : String(format: L("%d 天"), value)
    }
}

/// 「日志」二级页：查看 / 清空 / 导出运行日志。
struct LogsView: View {
    @ObservedObject private var store = LogStore.shared
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var showingClearConfirmation = false
    @State private var shareFailureMessage: String?
    @State private var showShareFailureAlert = false

    var body: some View {
        List {
            Section {
                Picker(L("日志保留"), selection: $store.retentionDays) {
                    ForEach(LogStore.retentionOptions, id: \.self) { value in
                        Text(retentionTitle(value)).tag(value)
                    }
                }
            } footer: {
                Text(L("超过保留天数的日志会被自动清理。"))
            }

            // 日志按块加载：进入时只有最近一块，更早的按需加载
            if store.canLoadMore {
                Section {
                    Button(L("加载更多")) {
                        store.loadMore()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            Section {
                if store.entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(L("暂无日志"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(store.entries.reversed()) { entry in
                        logRow(entry)
                    }
                }
            }
        }
        .navigationTitle(L("日志"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { export() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(store.entries.isEmpty)
                .accessibilityLabel(L("导出日志"))
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(store.entries.isEmpty)
                .accessibilityLabel(L("清空日志"))
            }
        }
        .alert(L("清空日志？"), isPresented: $showingClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清空"), role: .destructive) { store.clear() }
        } message: {
            Text(L("所有日志将被删除，此操作无法撤销。"))
        }
        .alert(L("导出失败"), isPresented: $showShareFailureAlert) {
            Button(L("确定"), role: .cancel) {}
        } message: {
            Text(shareFailureMessage ?? L("无法导出日志"))
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.level.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: entry.level))
                Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.message)
                .font(.footnote)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func retentionTitle(_ value: Int) -> String {
        value == 0 ? L("无限制") : String(format: L("%d 天"), value)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    /// contextMenu / 工具栏点击后同步 present 会被丢弃，延后一拍再弹分享面板。
    private func export() {
        guard let url = store.exportFileURL() else {
            shareFailureMessage = L("无法导出日志")
            showShareFailureAlert = true
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            SharePresenter.present(items: [url])
        }
    }
}

/// Cookie 的读取 / 删除封装。
///
/// WKWebView 用的是持久化数据存储，登录状态（Cookie）本来就会跨启动保存；
/// 这里给设置页提供「查看 + 清理」的能力（换账号、怀疑登录态串了时用得上）。
enum CookieManager {
    struct Group: Identifiable {
        let domain: String
        let count: Int

        var id: String { domain }
    }

    /// 读取全部 Cookie，按站点域名归组（去掉前导点，`.a.com` 与 `a.com` 归为一组）。
    static func groups() async -> [Group] {
        let cookies = await allCookies()
        var counts: [String: Int] = [:]

        for cookie in cookies {
            counts[displayDomain(cookie.domain), default: 0] += 1
        }

        return counts
            .map { Group(domain: $0.key, count: $0.value) }
            .sorted { $0.domain < $1.domain }
    }

    /// 只删除某个站点的 Cookie。
    static func delete(domain: String) async {
        let store = WKWebsiteDataStore.default()
        let cookies = await allCookies().filter { displayDomain($0.domain) == domain }

        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.httpCookieStore.delete(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    /// 清空所有 Cookie（不影响本地存储、网页缓存等其它网站数据）。
    static func clearAll() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(
                ofTypes: [WKWebsiteDataTypeCookies],
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    private static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func displayDomain(_ domain: String) -> String {
        var value = domain
        while value.hasPrefix(".") { value.removeFirst() }
        return value.isEmpty ? domain : value
    }
}

/// 「Cookie 管理」二级页：按站点列出已保存的 Cookie，可单独删除或整体清空。
struct CookiesView: View {
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var groups: [CookieManager.Group] = []
    @State private var isLoading = true
    @State private var showingClearConfirmation = false

    private var totalCount: Int { groups.reduce(0) { $0 + $1.count } }

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shield")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(L("暂无 Cookie"))
                        .foregroundStyle(.secondary)
                    Text(L("浏览网页并登录后，这里会显示保存的登录状态。"))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                Section {
                    LabeledContent(L("共计"), value: String(format: L("%d 个"), totalCount))
                }

                Section {
                    ForEach(groups) { group in
                        HStack {
                            Text(group.domain)
                            Spacer()
                            Text(String(format: L("%d 个"), group.count))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await CookieManager.delete(domain: group.domain)
                                    groups = await CookieManager.groups()
                                }
                            } label: {
                                Label(L("删除"), systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text(L("Cookie 用于保存网站登录状态。删除后，相关网站需要重新登录。"))
                }
            }
        }
        .navigationTitle(L("Cookie 管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { groups = await CookieManager.groups() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L("刷新"))
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(groups.isEmpty)
                .accessibilityLabel(L("清空 Cookie"))
            }
        }
        .task {
            groups = await CookieManager.groups()
            isLoading = false
        }
        .alert(L("清空 Cookie？"), isPresented: $showingClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清空"), role: .destructive) {
                Task {
                    await CookieManager.clearAll()
                    groups = await CookieManager.groups()
                }
            }
        } message: {
            Text(L("所有网站保存的 Cookie 将被删除，相关网站需要重新登录。"))
        }
    }
}
