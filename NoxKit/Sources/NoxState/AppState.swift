import Combine
import Foundation
import SwiftUI
import NoxCore

@MainActor
public final class AppState: ObservableObject {
    /// 可选的下载线程数范围
    public static let segmentCountRange = NoxDefaults.segmentCountRange
    /// 多线程下载的默认线程数
    public static let defaultSegmentCount = NoxDefaults.defaultSegmentCount

    /// m3u8 分片并发数范围。0 表示跟随「多线程下载」设置
    public static let m3u8ConcurrencyRange = NoxDefaults.m3u8ConcurrencyRange
    /// m3u8 分片并发数默认值：跟随「多线程下载」设置
    public static let defaultM3u8Concurrency = NoxDefaults.defaultM3u8Concurrency
    /// m3u8 分片并发上限。分片远小于字节分片、总数可达数百，开太大容易触发 CDN 限速
    public static let maxHLSConcurrency = NoxDefaults.maxHLSConcurrency
    /// 未开启「多线程下载」时，m3u8 使用的分片并发
    public static let defaultHLSConcurrency = NoxDefaults.defaultHLSConcurrency

    /// 同时下载任务数「无限制」的取值
    public static let unlimitedConcurrentDownloads = NoxDefaults.unlimitedConcurrentDownloads
    /// 同时下载任务数的可选项（0 = 无限制）
    public static let maxConcurrentDownloadsOptions = NoxDefaults.maxConcurrentDownloadsOptions
    /// 同时进行的下载任务数默认值
    public static let defaultMaxConcurrentDownloads = NoxDefaults.defaultMaxConcurrentDownloads

    /// 历史保留「无限制」的取值
    public static let unlimitedHistory = NoxDefaults.unlimitedHistory
    /// 历史「按条数」保留的可选上限（0 = 无限制）
    public static let historyCountOptions = NoxDefaults.historyCountOptions
    /// 历史「按条数」保留的默认上限
    public static let defaultHistoryCount = NoxDefaults.defaultHistoryCount
    /// 历史「按时间」保留的可选天数（0 = 无限制）
    public static let historyDayOptions = NoxDefaults.historyDayOptions
    /// 历史「按时间」保留的默认天数
    public static let defaultHistoryDays = NoxDefaults.defaultHistoryDays

    @Published public var history: [HistoryItem] = []
    /// 浏览页收藏的书签（最新在最前）
    @Published public var bookmarks: [Bookmark] = []
    @Published public var downloads: [DownloadRecord] = []

    /// 下载记录变化（驱动后台保活的启停）。
    public var downloadsPublisher: AnyPublisher<[DownloadRecord], Never> {
        $downloads.eraseToAnyPublisher()
    }
    @Published public var preferredQuality: PreferredQuality = .ask
    /// 实验性：多线程（分片）下载
    @Published public var experimentalMultiThreadDownload = false
    /// 下载线程数（1...32），仅在多线程下载开启时生效
    @Published public var multiThreadSegmentCount: Int = AppState.defaultSegmentCount
    /// m3u8 分片并发数（0...32）。0 = 跟随「多线程下载」设置
    @Published public var m3u8SegmentConcurrency: Int = AppState.defaultM3u8Concurrency
    /// 同时进行的下载任务数（见 `maxConcurrentDownloadsOptions`，0 = 无限制）。每个任务内部还会再开分片连接
    @Published public var maxConcurrentDownloads: Int = AppState.defaultMaxConcurrentDownloads

    /// 下载网络：无线局域网与蜂窝 / 仅无线局域网。
    /// 后者会把所有下载请求的 `allowsCellularAccess` 置为 false。
    @Published public var downloadNetworkMode: DownloadNetworkMode = NoxDefaults.defaultDownloadNetworkMode

    /// 后台保活方式：关闭 / 静音音频 / 画中画。
    /// 默认走画中画：它不占用音频会话，不会打断其他 App 正在播放的音频。
    @Published public var keepAliveMode: KeepAliveMode = .pictureInPicture
    /// 画中画共存保护不可用时怎么办（继续用画中画 / 改用静音音频 / 停止保活）。
    @Published public var pipCoexistenceFallback: PiPCoexistenceFallback = .keepAlive

    /// 保活模式：跟随下载任务（默认）/ 启动即常驻。
    @Published public var keepAliveLifetime: KeepAliveLifetime = .followTasks

    /// 画中画悬浮窗高度（pt）。0 = 最小化（实际 0.1pt，视觉隐藏），越大窗口越高。
    @Published public var pipWindowHeight: Double = AppState.defaultPiPWindowHeight

    /// 画中画详细日志：开启后输出启动、就绪判断、重试和系统回调等诊断信息。
    @Published public var pipVerboseLogging = false

    /// 画中画窗口高度可选范围：0（最小/隐藏）… 最大可见小窗。
    public static let pipWindowHeightRange: ClosedRange<Double> = NoxDefaults.pipWindowHeightRange
    /// 默认最小化：不影响操作。
    public static let defaultPiPWindowHeight: Double = NoxDefaults.defaultPiPWindowHeight
    /// 实际布局用的最小高度：0.1pt，视觉隐藏。
    public static let minimizedPiPWindowHeight: Double = NoxDefaults.minimizedPiPWindowHeight

    /// 历史记录的保留方式：按条数 / 按时间
    @Published public var historyRetentionMode: HistoryRetentionMode = .count
    /// 「按条数」保留时的上限（见 `historyCountOptions`）
    @Published public var historyRetentionCount: Int = AppState.defaultHistoryCount
    /// 「按时间」保留时的天数上限（见 `historyDayOptions`）
    @Published public var historyRetentionDays: Int = AppState.defaultHistoryDays

    /// 外观模式：跟随系统 / 浅色 / 深色
    @Published public var appearanceMode: AppearanceMode = .system

    /// 被用户关闭的站点标识（未列入即视为开启）
    @Published private var disabledSiteIDs: Set<String> = []
    /// 站点开关的变更序号。`@Published` 在属性写入前广播，
    /// 浏览器页不能用它的旧值立刻重算，改为在写入完成后递增这里。
    @Published public private(set) var siteAvailabilityRevision = 0

    private let historyKey = "Nox.history"
    private let bookmarksKey = "Nox.bookmarks"
    private let downloadsKey = "Nox.downloads"
    private let qualityKey = "Nox.quality"
    private let multiThreadKey = "Nox.multiThreadDownload"
    private let segmentCountKey = "Nox.multiThreadSegmentCount"
    private let m3u8ConcurrencyKey = "Nox.m3u8SegmentConcurrency"
    private let maxConcurrentDownloadsKey = "Nox.maxConcurrentDownloads"
    private let downloadNetworkModeKey = "Nox.downloadNetworkMode"
    private let keepAliveModeKey = "Nox.keepAliveMode"
    private let pipCoexistenceFallbackKey = "Nox.pipCoexistenceFallback"
    private let keepAliveLifetimeKey = "Nox.keepAliveLifetime"
    private let pipWindowHeightKey = "Nox.pipWindowHeight"
    private let pipVerboseLoggingKey = "Nox.pipVerboseLogging"
    /// 旧版「是否以最小化显示」开关的键，仅用于读盘迁移。
    private let pipMinimizedKey = "Nox.pipMinimized"
    private let historyRetentionModeKey = "Nox.historyRetentionMode"
    private let historyRetentionCountKey = "Nox.historyRetentionCount"
    private let historyRetentionDaysKey = "Nox.historyRetentionDays"
    private let appearanceModeKey = "Nox.appearanceMode"
    private let disabledSitesKey = "Nox.disabledSites"

    public init() {
        load()
    }

    // MARK: - 历史

    /// 追加一条历史。
    ///
    /// 同一页面只保留最新一条：用 `URL.pageIdentity` 而不是原样比较 ——
    /// 同一个页面常带不同的跟踪参数（`utm_*`、`spm_id_from`…），
    /// 逐字比较会让它反复堆出新记录，历史页很快被同一页刷满。
    public func addHistory(title: String, url: URL) {
        let identity = url.pageIdentity

        history.removeAll { $0.url.pageIdentity == identity }

        history.insert(
            HistoryItem(id: UUID(), title: title, url: url, visitedAt: .now),
            at: 0
        )
        applyHistoryRetention()
        persist()
    }

    /// 按当前保留策略裁剪历史。
    ///
    /// - 按条数：只保留最新的 N 条；
    /// - 按时间：丢弃超过 N 天的记录。
    public func applyHistoryRetention() {
        switch historyRetentionMode {
        case .count:
            // 0 = 无限制：不做裁剪
            guard historyRetentionCount != Self.unlimitedHistory else { return }

            let limit = max(1, historyRetentionCount)
            if history.count > limit {
                history = Array(history.prefix(limit))
            }
        case .days:
            // 0 = 无限制：永不过期
            guard historyRetentionDays != Self.unlimitedHistory else { return }

            let cutoff = Calendar.current.date(
                byAdding: .day,
                value: -max(1, historyRetentionDays),
                to: .now
            ) ?? .distantPast
            history.removeAll { $0.visitedAt < cutoff }
        }
    }

    /// 删除某个页面（按归一化身份）对应的历史记录。
    ///
    /// 取消下载时会调用：被取消的任务不应留在历史里。
    public func removeHistory(matching url: URL?) {
        guard let url else { return }
        let identity = url.pageIdentity
        history.removeAll { $0.url.pageIdentity == identity }
        persist()
    }

    public func removeHistory(_ item: HistoryItem) {
        history.removeAll { $0.id == item.id }
        persist()
    }

    /// 批量删除（历史页多选时用）
    public func removeHistory(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }

        history.removeAll { ids.contains($0.id) }
        persist()
    }

    public func clearHistory() {
        history.removeAll()
        persist()
    }

    // MARK: - 书签

    /// 当前页面是否已收藏（按归一化后的页面身份判断）。
    public func isBookmarked(_ url: URL) -> Bool {
        let identity = url.pageIdentity
        return bookmarks.contains { $0.url.pageIdentity == identity }
    }

    /// 收藏 / 取消收藏当前页面。已在书签里则移除，否则插到最前。
    public func toggleBookmark(title: String, url: URL) {
        let identity = url.pageIdentity

        if let index = bookmarks.firstIndex(where: { $0.url.pageIdentity == identity }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.insert(Bookmark(title: title, url: url), at: 0)
        }

        persist()
    }

    public func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persist()
    }

    // MARK: - 下载

    public func addDownload(_ record: DownloadRecord) {
        downloads.insert(record, at: 0)
        persist()
    }

    /// - Parameter persist: 高频进度回调传 false，避免每秒写 UserDefaults。
    public func updateDownload(_ record: DownloadRecord, persist shouldPersist: Bool = true) {
        guard let index = downloads.firstIndex(where: { $0.id == record.id }) else {
            return
        }

        downloads[index] = record

        if shouldPersist {
            persist()
        }
    }

    public func removeDownload(_ record: DownloadRecord) {
        downloads.removeAll { $0.id == record.id }
        persist()
    }

    public func clearFinishedDownloads() {
        downloads.removeAll {
            $0.status == .finished ||
            $0.status == .failed ||
            $0.status == .cancelled
        }
        persist()
    }

    // MARK: - 站点开关

    public func isSiteEnabled(_ identifier: String) -> Bool {
        !disabledSiteIDs.contains(identifier)
    }

    public func setSite(_ identifier: String, enabled: Bool) {
        if enabled {
            disabledSiteIDs.remove(identifier)
        } else {
            disabledSiteIDs.insert(identifier)
        }
        siteAvailabilityRevision &+= 1
        persist()
    }

    // MARK: - 持久化

    public func persist() {
        let defaults = UserDefaults.standard

        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }

        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: bookmarksKey)
        }

        if let data = try? JSONEncoder().encode(downloads) {
            defaults.set(data, forKey: downloadsKey)
        }

        defaults.set(preferredQuality.rawValue, forKey: qualityKey)
        defaults.set(experimentalMultiThreadDownload, forKey: multiThreadKey)
        defaults.set(multiThreadSegmentCount, forKey: segmentCountKey)
        defaults.set(m3u8SegmentConcurrency, forKey: m3u8ConcurrencyKey)
        defaults.set(maxConcurrentDownloads, forKey: maxConcurrentDownloadsKey)
        defaults.set(downloadNetworkMode.rawValue, forKey: downloadNetworkModeKey)
        defaults.set(keepAliveMode.rawValue, forKey: keepAliveModeKey)
        defaults.set(pipCoexistenceFallback.rawValue, forKey: pipCoexistenceFallbackKey)
        defaults.set(keepAliveLifetime.rawValue, forKey: keepAliveLifetimeKey)
        defaults.set(pipWindowHeight, forKey: pipWindowHeightKey)
        defaults.set(pipVerboseLogging, forKey: pipVerboseLoggingKey)
        defaults.set(historyRetentionMode.rawValue, forKey: historyRetentionModeKey)
        defaults.set(historyRetentionCount, forKey: historyRetentionCountKey)
        defaults.set(historyRetentionDays, forKey: historyRetentionDaysKey)
        defaults.set(appearanceMode.rawValue, forKey: appearanceModeKey)
        defaults.set(Array(disabledSiteIDs).sorted(), forKey: disabledSitesKey)
    }

    private func load() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: historyKey),
           let value = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = value
        }

        if let data = defaults.data(forKey: bookmarksKey),
           let value = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = value
        }

        if let data = defaults.data(forKey: downloadsKey),
           let value = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            // 进程被系统回收时任务不会回调，残留的 .downloading 需要归位，
            // 否则会永远显示「下载中」且无法重试。
            downloads = value.map { record in
                guard record.status == .downloading else { return record }
                var updated = record
                updated.status = .cancelled
                updated.errorMessage = nil
                return updated
            }
        }

        preferredQuality = PreferredQuality.migrated(from: defaults.string(forKey: qualityKey))
        experimentalMultiThreadDownload = defaults.bool(forKey: multiThreadKey)

        let storedSegments = defaults.integer(forKey: segmentCountKey)
        multiThreadSegmentCount = Self.segmentCountRange.contains(storedSegments)
            ? storedSegments
            : Self.defaultSegmentCount

        // 0 是合法值（= 跟随多线程设置），恰好也是 defaults.integer 缺键时的返回值，
        // 所以两者天然一致，不需要额外区分「键不存在」。
        let storedConcurrency = defaults.integer(forKey: m3u8ConcurrencyKey)
        m3u8SegmentConcurrency = Self.m3u8ConcurrencyRange.contains(storedConcurrency)
            ? storedConcurrency
            : Self.defaultM3u8Concurrency

        // 0（无限制）是合法取值，而 `integer(forKey:)` 在缺键时也返回 0，
        // 所以要用 `object(forKey:)` 区分「没存过」与「存的就是无限制」。
        if let stored = defaults.object(forKey: maxConcurrentDownloadsKey) as? Int,
           Self.maxConcurrentDownloadsOptions.contains(stored) {
            maxConcurrentDownloads = stored
        } else {
            maxConcurrentDownloads = Self.defaultMaxConcurrentDownloads
        }

        downloadNetworkMode = DownloadNetworkMode(
            rawValue: defaults.string(forKey: downloadNetworkModeKey) ?? ""
        ) ?? NoxDefaults.defaultDownloadNetworkMode

        historyRetentionMode = HistoryRetentionMode(
            rawValue: defaults.string(forKey: historyRetentionModeKey) ?? ""
        ) ?? .count

        let storedCount = defaults.integer(forKey: historyRetentionCountKey)
        historyRetentionCount = Self.historyCountOptions.contains(storedCount)
            ? storedCount
            : Self.defaultHistoryCount

        let storedDays = defaults.integer(forKey: historyRetentionDaysKey)
        historyRetentionDays = Self.historyDayOptions.contains(storedDays)
            ? storedDays
            : Self.defaultHistoryDays

        appearanceMode = AppearanceMode(
            rawValue: defaults.string(forKey: appearanceModeKey) ?? ""
        ) ?? .system

        keepAliveMode = KeepAliveMode(
            rawValue: defaults.string(forKey: keepAliveModeKey) ?? ""
        ) ?? .pictureInPicture

        pipCoexistenceFallback = PiPCoexistenceFallback(
            rawValue: defaults.string(forKey: pipCoexistenceFallbackKey) ?? ""
        ) ?? .keepAlive

        keepAliveLifetime = KeepAliveLifetime(
            rawValue: defaults.string(forKey: keepAliveLifetimeKey) ?? ""
        ) ?? .followTasks

        // 滑块值；缺键时回落到旧版「最小化」开关做迁移，再回落到默认（最小）。
        if let stored = defaults.object(forKey: pipWindowHeightKey) as? Double {
            pipWindowHeight = Self.pipWindowHeightRange.contains(stored)
                ? stored
                : Self.defaultPiPWindowHeight
        } else if let legacy = defaults.object(forKey: pipMinimizedKey) as? Bool {
            pipWindowHeight = legacy ? Self.defaultPiPWindowHeight : Self.pipWindowHeightRange.upperBound
        } else {
            pipWindowHeight = Self.defaultPiPWindowHeight
        }

        pipVerboseLogging = defaults.bool(forKey: pipVerboseLoggingKey)

        disabledSiteIDs = Set(defaults.stringArray(forKey: disabledSitesKey) ?? [])

        // 读盘后先按当前保留策略裁剪一次，避免旧数据一直撑着。
        applyHistoryRetention()
    }
}

// MARK: - App 语言与查表

/// App 当前生效的语言与区域设置。
/// 不依赖 MainActor，方便 `TransferStats`、日期格式化等纯计算逻辑复用。
