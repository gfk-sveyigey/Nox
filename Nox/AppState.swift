import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    /// 可选的下载线程数范围
    static let segmentCountRange = 1...32
    /// 多线程下载的默认线程数
    static let defaultSegmentCount = 4

    @Published var history: [HistoryItem] = []
    @Published var downloads: [DownloadRecord] = []
    @Published var preferredQuality: PreferredQuality = .ask
    /// 实验性：多线程（分片）下载
    @Published var experimentalMultiThreadDownload = false
    /// 下载线程数（1...32），仅在多线程下载开启时生效
    @Published var multiThreadSegmentCount: Int = AppState.defaultSegmentCount
    /// 被用户关闭的站点标识（未列入即视为开启）
    @Published private var disabledSiteIDs: Set<String> = []

    private let historyKey = "Nox.history"
    private let downloadsKey = "Nox.downloads"
    private let qualityKey = "Nox.quality"
    private let multiThreadKey = "Nox.multiThreadDownload"
    private let segmentCountKey = "Nox.multiThreadSegmentCount"
    private let disabledSitesKey = "Nox.disabledSites"

    init() {
        load()
    }

    // MARK: - 历史

    func addHistory(title: String, url: URL) {
        history.removeAll { $0.url == url }
        history.insert(
            HistoryItem(id: UUID(), title: title, url: url, visitedAt: .now),
            at: 0
        )
        history = Array(history.prefix(50))
        persist()
    }

    func removeHistory(_ item: HistoryItem) {
        history.removeAll { $0.id == item.id }
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

        disabledSiteIDs = Set(defaults.stringArray(forKey: disabledSitesKey) ?? [])
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