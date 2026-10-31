import Foundation

/// App 当前生效的语言与区域设置。
/// 不依赖 MainActor，方便 `TransferStats`、日期格式化等纯计算逻辑复用。
public enum AppLocale {
    public static let languageKey = "Nox.appLanguage"

    /// 用户在设置里选定的语言；`nil` = 跟随系统
    public static var selectedCode: String? {
        let stored = UserDefaults.standard.string(forKey: languageKey)
        guard let stored, !stored.isEmpty, stored != "system" else { return nil }
        return stored
    }

    /// 数字/日期格式化用
    public static var current: Locale {
        selectedCode.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    /// 文本查表用的资源包。
    ///
    /// - 跟随系统：返回 `Bundle.main`，由 iOS 按「系统偏好语言 ∩ CFBundleLocalizations」挑选；
    /// - 指定语言：直接指向 `<code>.lproj`。
    ///
    /// 若目标 `.lproj` 不存在（例如资源未打进包），回落到 `Bundle.main`，
    /// 此时显示的是开发语言（`CFBundleDevelopmentRegion`）的文本，便于发现资源缺失。
    public static var bundle: Bundle {
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
public func L(_ key: String) -> String {
    // zh-Hans 是 string catalog 的 sourceLanguage，Xcode 不会为源语言生成
    // 独立的 zh-Hans.lproj，源语言文本就是 key 本身。
    // 若此时回落到 Bundle.main，在英文系统上会错误地取到 en.lproj 的翻译
    // （表现为：App 内选“简体中文”，界面却变成英文）。
    if AppLocale.selectedCode == AppLanguage.simplifiedChinese.rawValue,
       Bundle.main.path(forResource: "zh-Hans", ofType: "lproj") == nil {
        return key
    }

    // 等价写法：NSLocalizedString(key, tableName: nil, bundle: AppLocale.bundle, value: key, comment: "")
    // 注意：全局函数 NSLocalizedString 的标签是 tableName；
    //       而 Bundle 实例方法 localizedString(forKey:value:table:) 的标签是 table。两者不要混用。
    return AppLocale.bundle.localizedString(forKey: key, value: key, table: nil)
}

// MARK: - 已持久化的本地化文案

/// 已打包语言对应的资源包（源语言 zh-Hans 不生成 .lproj，直接用 key 本身）。
private let qualityLabelBundles: [Bundle] = ["en", "de", "fr", "ko"].compactMap { code in
    guard let path = Bundle.main.path(forResource: code, ofType: "lproj") else { return nil }
    return Bundle(path: path)
}

/// 需要按当前语言重译的清晰度标签。长的在前：「仅视频」包含「视频」，
/// 反序替换会拼出「仅Video」。
private let qualityLabelKeys = ["页面嗅探", "网络嗅探", "播放器提取", "仅视频", "音频", "视频"]

/// key → 该文案在所有已打包语言里的写法（含源语言的 key 本身）。
private let qualityLabelVariants: [String: [String]] = qualityLabelKeys.reduce(into: [:]) { result, key in
    result[key] = [key] + qualityLabelBundles.map {
        $0.localizedString(forKey: key, value: key, table: nil)
    }
}

/// 把「按下载当时的语言存下来的」清晰度文案翻译成当前语言。
///
/// 下载记录里的 `quality` 会持久化：嗅探来源（页面嗅探 / 网络嗅探 / 播放器提取）
/// 与 YouTube 的音频 / 仅视频标记在旧版本中直接存了本地化文本，切语言后不会自己变。
/// 这里按已知标签做整段替换；`1080p` 这类不含标签的部分原样保留。
public func translatedQualityLabel(_ raw: String) -> String {
    guard !raw.isEmpty else { return raw }

    var result = raw

    for key in qualityLabelKeys {
        let target = L(key)

        for value in qualityLabelVariants[key] ?? [] where !value.isEmpty && value != target {
            result = result.replacingOccurrences(of: value, with: target)
        }
    }

    return result
}
