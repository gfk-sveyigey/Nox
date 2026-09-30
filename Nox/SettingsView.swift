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

    /// 所有设置项放在同一个列表里，不做分组。
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
                HistorySettingsView()
            } label: {
                Text(L("历史记录"))
            }

            NavigationLink {
                LogsView()
            } label: {
                Text(L("日志"))
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

            LabeledContent(L("版本"), value: "v\(Self.appVersion)")
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

/// 「储存空间」二级页：按类别展示占用。
///
/// 多选逻辑与「下载 / 历史」页保持一致：点「选择」或双指下滑进入多选，
/// 勾选任意几类后由右上角的「清理」统一清理。
struct StorageSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var manager: DownloadManager

    @State private var sizes: [StorageCategory: Int64] = [:]
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<StorageCategory>()
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
        // 与下载 / 历史页一致：双指下滑进入多选
        .twoFingerPanToSelect(isEnabled: isVisible) {
            withAnimation { editMode = .active }
        }
        .alert(L("清理所选？"), isPresented: $showingClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清理"), role: .destructive) { clearSelected() }
        } message: {
            Text(L("所选类别的缓存与文件将被删除，此操作无法撤销。"))
        }
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
        // 多选只通过双指下滑进入；进入后在返回键的位置显示「完成」。
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

            LogStore.shared.info("storage cleared: " + categories.map(\.rawValue).sorted().joined(separator: ","))

            refresh()
        }
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
