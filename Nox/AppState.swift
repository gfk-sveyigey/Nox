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

// MARK: - App 语言

/// App 内可选的显示语言。
///
/// - `system`：不设任何覆盖，交给 iOS 按「系统偏好语言 ∩ App 支持语言」选择，
///   系统语言不在支持列表时回落到 `CFBundleDevelopmentRegion`（en）。
/// - 其余 case 的 `rawValue` 必须与 `.lproj` 目录名一致。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case korean = "ko"
    case french = "fr"
    case german = "de"

    var id: String { rawValue }

    /// `nil` 表示跟随系统（清除覆盖）
    var resolvedCode: String? {
        self == .system ? nil : rawValue
    }

    /// 语言名用其本族语言书写，便于用户识别
    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
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

    /// 当前选择（修改后立即生效，无需重启）
    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            apply()
        }
    }

    private let storageKey = "Nox.appLanguage"

    private init() {
        let stored = UserDefaults.standard.string(forKey: storageKey)
        language = AppLanguage(rawValue: stored ?? "") ?? .system

        // 启动时立刻应用一次，确保首帧就是正确语言
        Bundle.applyAppLanguage(language.resolvedCode)
    }

    /// 交给 `\.locale`，让日期、数字格式跟随所选语言
    var locale: Locale {
        guard let code = language.resolvedCode else { return .autoupdatingCurrent }
        return Locale(identifier: code)
    }

    private func apply() {
        UserDefaults.standard.set(language.rawValue, forKey: storageKey)
        Bundle.applyAppLanguage(language.resolvedCode)
    }
}

// MARK: - Bundle 语言覆盖

private var appLanguageBundleKey: UInt8 = 0

/// 按「用户所选语言」查表，而不是按进程启动时的系统语言。
private final class AppLanguageBundle: Bundle {
    override func localizedString(
        forKey key: String,
        value: String?,
        table tableName: String?
    ) -> String {
        guard let path = objc_getAssociatedObject(self, &appLanguageBundleKey) as? String,
              let languageBundle = Bundle(path: path) else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }

        // languageBundle 是普通 Bundle，不会再走到这里，不会递归
        return languageBundle.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// - Parameter code: `nil` = 跟随系统；否则为 `en` / `zh-Hans` / `ko` / `fr` / `de`
    static func applyAppLanguage(_ code: String?) {
        // 把 Bundle.main 的 localizedString 换成我们自己的实现，只需替换一次
        if !(Bundle.main is AppLanguageBundle) {
            object_setClass(Bundle.main, AppLanguageBundle.self)
        }

        guard let code,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              Bundle(path: path) != nil else {
            // 跟随系统：清掉覆盖，回到系统语言
            objc_setAssociatedObject(
                Bundle.main,
                &appLanguageBundleKey,
                nil,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            return
        }

        objc_setAssociatedObject(
            Bundle.main,
            &appLanguageBundleKey,
            path,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}