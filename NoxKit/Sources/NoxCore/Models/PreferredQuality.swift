import Foundation

/// 下载清晰度偏好。
/// 用稳定代码（rawValue）持久化，而不是本地化后的标题，
/// 这样切换系统语言后已保存的设置不会失效。
public enum PreferredQuality: String, CaseIterable, Identifiable {
    case ask
    case best
    case p1080
    case p720
    case p480
    case p360

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ask: return L("每次询问")
        case .best: return L("最佳")
        case .p1080: return "1080P"
        case .p720: return "720P"
        case .p480: return "480P"
        case .p360: return "360P"
        }
    }

    /// 期望的清晰度数值；`.ask` / `.best` 返回 0
    public var qualityNumber: Int {
        Int(rawValue.filter(\.isNumber)) ?? 0
    }

    /// 兼容旧版本（直接存了中文/英文标题）的已保存值
    public static func migrated(from raw: String?) -> PreferredQuality {
        guard let raw, !raw.isEmpty else { return .ask }
        if let value = PreferredQuality(rawValue: raw) { return value }

        switch raw {
        case "每次询问", "Ask Every Time": return .ask
        case "最佳", "Best": return .best
        case "1080": return .p1080
        case "720": return .p720
        case "480": return .p480
        case "360": return .p360
        default: return .ask
        }
    }
}
