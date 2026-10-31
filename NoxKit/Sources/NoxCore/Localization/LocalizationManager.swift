import Combine
import Foundation

@MainActor
public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()

    /// 当前选择。改变后观察本对象的视图会自动刷新；设置页额外由
    /// `ContentView` 的 `.id(language)` 强制重建，避免 Picker 选项残留旧文案。
    /// 这里只负责持久化与对外暴露 `locale`。
    @Published public var language: AppLanguage {
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
    public var locale: Locale { AppLocale.current }
}
