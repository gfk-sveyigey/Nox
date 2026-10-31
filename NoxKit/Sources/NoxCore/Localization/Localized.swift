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
