import Foundation

/// App 内可选的显示语言。
///
/// - `system`：不设任何覆盖，交给 iOS 按「系统偏好语言 ∩ App 支持语言」选择，
///   系统语言不在支持列表时回落到 `CFBundleDevelopmentRegion`。
/// - 其余 case 的 `rawValue` 必须与 `.lproj` 目录名一致。
public enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case korean = "ko"
    case french = "fr"
    case german = "de"

    public var id: String { rawValue }

    /// 语言名用其本族语言书写，便于用户识别
    public var title: String {
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
