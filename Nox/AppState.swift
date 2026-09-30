import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    /// 可选的下载线程数范围
    static let segmentCountRange = 1...32
    /// 多线程下载的默认线程数
    static let defaultSegmentCount = 4

    /// m3u8 分片并发数范围。0 表示跟随「多线程下载」设置
    static let m3u8ConcurrencyRange = 0...32
    /// m3u8 分片并发数默认值：跟随「多线程下载」设置
    static let defaultM3u8Concurrency = 0
    /// m3u8 分片并发上限。分片远小于字节分片、总数可达数百，开太大容易触发 CDN 限速
    static let maxHLSConcurrency = 32
    /// 未开启「多线程下载」时，m3u8 使用的分片并发
    static let defaultHLSConcurrency = 4

    /// 同时下载任务数「无限制」的取值
    static let unlimitedConcurrentDownloads = 0
    /// 同时下载任务数的可选项（0 = 无限制）
    static let maxConcurrentDownloadsOptions = [1, 3, 5, 10, 20, unlimitedConcurrentDownloads]
    /// 同时进行的下载任务数默认值
    static let defaultMaxConcurrentDownloads = 3

    /// 历史保留「无限制」的取值
    static let unlimitedHistory = 0
    /// 历史「按条数」保留的可选上限（0 = 无限制）
    static let historyCountOptions = [20, 50, 100, 200, 500, unlimitedHistory]
    /// 历史「按条数」保留的默认上限
    static let defaultHistoryCount = 50
    /// 历史「按时间」保留的可选天数（0 = 无限制）
    static let historyDayOptions = [1, 3, 7, 30, 90, unlimitedHistory]
    /// 历史「按时间」保留的默认天数
    static let defaultHistoryDays = 30

    @Published var history: [HistoryItem] = []
    @Published var downloads: [DownloadRecord] = []
    @Published var preferredQuality: PreferredQuality = .ask
    /// 实验性：多线程（分片）下载
    @Published var experimentalMultiThreadDownload = false
    /// 下载线程数（1...32），仅在多线程下载开启时生效
    @Published var multiThreadSegmentCount: Int = AppState.defaultSegmentCount
    /// m3u8 分片并发数（0...32）。0 = 跟随「多线程下载」设置
    @Published var m3u8SegmentConcurrency: Int = AppState.defaultM3u8Concurrency
    /// 同时进行的下载任务数（见 `maxConcurrentDownloadsOptions`，0 = 无限制）。每个任务内部还会再开分片连接
    @Published var maxConcurrentDownloads: Int = AppState.defaultMaxConcurrentDownloads

    /// 历史记录的保留方式：按条数 / 按时间
    @Published var historyRetentionMode: HistoryRetentionMode = .count
    /// 「按条数」保留时的上限（见 `historyCountOptions`）
    @Published var historyRetentionCount: Int = AppState.defaultHistoryCount
    /// 「按时间」保留时的天数上限（见 `historyDayOptions`）
    @Published var historyRetentionDays: Int = AppState.defaultHistoryDays

    /// 外观模式：跟随系统 / 浅色 / 深色
    @Published var appearanceMode: AppearanceMode = .system

    /// 被用户关闭的站点标识（未列入即视为开启）
    @Published private var disabledSiteIDs: Set<String> = []

    private let historyKey = "Nox.history"
    private let downloadsKey = "Nox.downloads"
    private let qualityKey = "Nox.quality"
    private let multiThreadKey = "Nox.multiThreadDownload"
    private let segmentCountKey = "Nox.multiThreadSegmentCount"
    private let m3u8ConcurrencyKey = "Nox.m3u8SegmentConcurrency"
    private let maxConcurrentDownloadsKey = "Nox.maxConcurrentDownloads"
    private let historyRetentionModeKey = "Nox.historyRetentionMode"
    private let historyRetentionCountKey = "Nox.historyRetentionCount"
    private let historyRetentionDaysKey = "Nox.historyRetentionDays"
    private let appearanceModeKey = "Nox.appearanceMode"
    private let disabledSitesKey = "Nox.disabledSites"

    init() {
        load()
    }

    // MARK: - 历史

    /// 追加一条历史。
    ///
    /// 同一页面只保留最新一条：用 `URL.pageIdentity` 而不是原样比较 ——
    /// 同一个页面常带不同的跟踪参数（`utm_*`、`spm_id_from`…），
    /// 逐字比较会让它反复堆出新记录，历史页很快被同一页刷满。
    func addHistory(title: String, url: URL) {
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
    func applyHistoryRetention() {
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
    func removeHistory(matching url: URL?) {
        guard let url else { return }
        let identity = url.pageIdentity
        history.removeAll { $0.url.pageIdentity == identity }
        persist()
    }

    func removeHistory(_ item: HistoryItem) {
        history.removeAll { $0.id == item.id }
        persist()
    }

    /// 批量删除（历史页多选时用）
    func removeHistory(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }

        history.removeAll { ids.contains($0.id) }
        persist()
    }

    func clearHistory() {
        history.removeAll()
        persist()
    }

    // MARK: - 下载

    func addDownload(_ record: DownloadRecord) {
        downloads.insert(record, at: 0)
        persist()
    }

    /// - Parameter persist: 高频进度回调传 false，避免每秒写 UserDefaults。
    func updateDownload(_ record: DownloadRecord, persist shouldPersist: Bool = true) {
        guard let index = downloads.firstIndex(where: { $0.id == record.id }) else {
            return
        }

        downloads[index] = record

        if shouldPersist {
            persist()
        }
    }

    func removeDownload(_ record: DownloadRecord) {
        downloads.removeAll { $0.id == record.id }
        persist()
    }

    func clearFinishedDownloads() {
        downloads.removeAll {
            $0.status == .finished ||
            $0.status == .failed ||
            $0.status == .cancelled
        }
        persist()
    }

    // MARK: - 站点开关

    func isSiteEnabled(_ identifier: String) -> Bool {
        !disabledSiteIDs.contains(identifier)
    }

    func setSite(_ identifier: String, enabled: Bool) {
        if enabled {
            disabledSiteIDs.remove(identifier)
        } else {
            disabledSiteIDs.insert(identifier)
        }
        persist()
    }

    // MARK: - 持久化

    func persist() {
        let defaults = UserDefaults.standard

        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }

        if let data = try? JSONEncoder().encode(downloads) {
            defaults.set(data, forKey: downloadsKey)
        }

        defaults.set(preferredQuality.rawValue, forKey: qualityKey)
        defaults.set(experimentalMultiThreadDownload, forKey: multiThreadKey)
        defaults.set(multiThreadSegmentCount, forKey: segmentCountKey)
        defaults.set(m3u8SegmentConcurrency, forKey: m3u8ConcurrencyKey)
        defaults.set(maxConcurrentDownloads, forKey: maxConcurrentDownloadsKey)
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

        disabledSiteIDs = Set(defaults.stringArray(forKey: disabledSitesKey) ?? [])

        // 读盘后先按当前保留策略裁剪一次，避免旧数据一直撑着。
        applyHistoryRetention()
    }
}

// MARK: - App 语言与查表

/// App 当前生效的语言与区域设置。
/// 不依赖 MainActor，方便 `TransferStats`、日期格式化等纯计算逻辑复用。
enum AppLocale {
    static let languageKey = "Nox.appLanguage"

    /// 用户在设置里选定的语言；`nil` = 跟随系统
    static var selectedCode: String? {
        let stored = UserDefaults.standard.string(forKey: languageKey)
        guard let stored, !stored.isEmpty, stored != "system" else { return nil }
        return stored
    }

    /// 数字/日期格式化用
    static var current: Locale {
        selectedCode.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    /// 文本查表用的资源包。
    ///
    /// - 跟随系统：返回 `Bundle.main`，由 iOS 按「系统偏好语言 ∩ CFBundleLocalizations」挑选；
    /// - 指定语言：直接指向 `<code>.lproj`。
    ///
    /// 若目标 `.lproj` 不存在（例如资源未打进包），回落到 `Bundle.main`，
    /// 此时显示的是开发语言（`CFBundleDevelopmentRegion`）的文本，便于发现资源缺失。
    static var bundle: Bundle {
        guard let code = selectedCode,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}

/// 显式按「App 内选定的语言」查表，返回已解析的 String。
///
/// - 必须配合 `Text(_:)` / `Label(_:)` / `Button(_:)` 等 **StringProtocol** 重载使用：
///   `Text(L("设置"))`；
///   不要写成 `Text("设置")` —— 那是 `LocalizedStringKey` 重载，会重新走
///   `Bundle.main` 的解析结果，导致 App 内切语言后不生效。
/// - 带插值的文案用 `String(format:)`：
///   `String(format: L("页面加载失败：%@"), message)`
func L(_ key: String) -> String {
    // 等价写法：NSLocalizedString(key, tableName: nil, bundle: AppLocale.bundle, value: key, comment: "")
    // 注意：全局函数 NSLocalizedString 的标签是 tableName；
    //       而 Bundle 实例方法 localizedString(forKey:value:table:) 的标签是 table。两者不要混用。
    AppLocale.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// App 内可选的显示语言。
///
/// - `system`：不设任何覆盖，交给 iOS 按「系统偏好语言 ∩ App 支持语言」选择，
///   系统语言不在支持列表时回落到 `CFBundleDevelopmentRegion`。
/// - 其余 case 的 `rawValue` 必须与 `.lproj` 目录名一致。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case korean = "ko"
    case french = "fr"
    case german = "de"

    var id: String { rawValue }

    /// 语言名用其本族语言书写，便于用户识别
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        }
    }
}

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// 当前选择。改变后由视图层（`NoxApp` 的 `.id(language)`）负责重建界面，
    /// 这里只负责持久化与对外暴露 `locale`。
    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: AppLocale.languageKey)
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: AppLocale.languageKey)
        language = AppLanguage(rawValue: stored ?? "") ?? .system
    }

    /// 交给 `\.locale`，让日期、数字格式跟随所选语言
    var locale: Locale { AppLocale.current }
}

// MARK: - 历史保留策略与外观

/// 历史记录的保留方式。
enum HistoryRetentionMode: String, CaseIterable, Identifiable {
    /// 只保留最新的 N 条
    case count
    /// 只保留最近 N 天内的记录
    case days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .count: return L("按条数")
        case .days: return L("按时间")
        }
    }
}

/// 外观模式：跟随系统 / 浅色 / 深色。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }

    /// 传给 preferredColorScheme；system 返回 nil，交给系统决定。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
// MARK: - 日志

enum LogLevel: String, CaseIterable, Identifiable {
    case info
    case warning
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return L("信息")
        case .warning: return L("警告")
        case .error: return L("错误")
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String
}

/// 文件日志。
///
/// - 每条日志追加写入 `Application Support/Nox/Nox.log`；
/// - 「日志」页按块读取：进入时只加载**最近一块**（64 KB），滚到底点「加载更多」再往前读，
///   不会一次性把整份日志读进内存或列表；
/// - 可按天数保留（0 = 无限制），超期日志在写入与读取时都会被清理。
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// 「保留天数」可选项（0 = 无限制）
    static let retentionOptions = [1, 3, 7, 30, 90, 0]
    /// 保留天数默认值
    static let defaultRetentionDays = 30
    private static let retentionKey = "Nox.logRetentionDays"

    /// 当前已加载的日志（按时间升序，最新在最后）
    @Published private(set) var entries: [LogEntry] = []
    /// 是否还有更早的日志可以继续加载
    @Published private(set) var canLoadMore = false

    /// 日志保留天数；0 = 无限制
    @Published var retentionDays: Int {
        didSet {
            guard retentionDays != oldValue else { return }
            UserDefaults.standard.set(retentionDays, forKey: Self.retentionKey)
            pruneExpired()
            reload()
        }
    }

    /// 每次从文件尾部读取的字节数（分块加载，避免一次读入整份日志）
    private let pageBytes = 64 * 1024
    /// 当前已请求读取的字节数
    private var loadedBytes = 0
    /// 文件清理的节流时间戳
    private var lastFilePrune = Date.distantPast

    private let fileURL: URL
    private let dateFormatter: ISO8601DateFormatter

    private init() {
        let directory = DownloadStorage.rootDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("Nox.log")

        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        let stored = UserDefaults.standard.object(forKey: Self.retentionKey) as? Int
        retentionDays = stored.flatMap { Self.retentionOptions.contains($0) ? $0 : nil }
            ?? Self.defaultRetentionDays

        loadedBytes = pageBytes
        pruneExpired()
        reload()
    }

    func info(_ message: String) { log(.info, message) }
    func warning(_ message: String) { log(.warning, message) }
    func error(_ message: String) { log(.error, message) }

    func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(date: .now, level: level, message: message)
        entries.append(entry)
        appendToDisk(entry)
        pruneExpired()
    }

    /// 会话启动时记一条环境信息，方便排查问题。
    func recordSessionStart() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        info("session start · Nox v\(version)(\(build)) · \(os)")
    }

    /// 载入下一块更早的日志。
    func loadMore() {
        guard canLoadMore else { return }
        loadedBytes += pageBytes
        reload()
    }

    func clear() {
        entries.removeAll()
        canLoadMore = false
        loadedBytes = pageBytes
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 导出为可分享的临时文本文件；失败返回 nil。
    func exportFileURL() -> URL? {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nox-logs-\(Self.fileStamp()).txt")
        do {
            try exportText().write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch {
            return nil
        }
    }

    /// 导出整份日志（显式导出时读取全文，避免日常加载占用内存）。
    func exportText() -> String {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty {
            return text
        }
        return entries.map(line(for:)).joined(separator: "\n")
    }

    // MARK: - 读取

    private func reload() {
        let (text, truncated) = readTail(maxBytes: loadedBytes)
        canLoadMore = truncated

        entries = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap(Self.parse)
    }

    /// 从文件尾部往前读最多 `maxBytes`，返回文本与「是否还有更早内容」。
    private func readTail(maxBytes: Int) -> (String, Bool) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return ("", false) }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let truncated = size > UInt64(maxBytes)
        let start = truncated ? size - UInt64(maxBytes) : 0

        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()

        guard var text = String(data: data, encoding: .utf8) else {
            return ("", truncated)
        }

        // 从中间截断时，丢掉可能不完整的首行
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }

        return (text, truncated)
    }

    // MARK: - 写入与清理

    private func line(for entry: LogEntry) -> String {
        "\(dateFormatter.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] \(entry.message)"
    }

    private func appendToDisk(_ entry: LogEntry) {
        guard let data = (line(for: entry) + "\n").data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// 删除超过保留天数的日志（内存 + 文件；0 表示不清理）。
    private func pruneExpired() {
        guard retentionDays != 0 else { return }

        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -retentionDays,
            to: .now
        ) ?? .distantPast

        entries.removeAll { $0.date < cutoff }

        // 文件清理较贵，节流到每分钟最多一次
        guard Date().timeIntervalSince(lastFilePrune) >= 60 else { return }
        lastFilePrune = .now
        pruneFile(before: cutoff)
    }

    private func pruneFile(before cutoff: Date) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.filter { line in
            // 解析不了的行不确定日期，保守保留
            guard let entry = Self.parse(line) else { return true }
            return entry.date >= cutoff
        }

        guard kept.count != lines.count else { return }

        let out = kept.map(String.init).joined(separator: "\n") + "\n"
        try? out.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 解析单行：ISO8601 时间戳 + [级别] + 正文。
    private static func parse(_ line: Substring) -> LogEntry? {
        guard let close = line.firstIndex(of: "]"),
              let open = line.firstIndex(of: "["),
              open < close else { return nil }

        let stamp = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let levelRaw = String(line[line.index(after: open)..<close]).lowercased()
        let message = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return LogEntry(
            date: formatter.date(from: stamp) ?? .distantPast,
            level: LogLevel(rawValue: levelRaw) ?? .info,
            message: message
        )
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}
