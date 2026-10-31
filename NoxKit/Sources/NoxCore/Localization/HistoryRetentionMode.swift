import Foundation

/// 历史记录的保留方式。
public enum HistoryRetentionMode: String, CaseIterable, Identifiable {
    /// 只保留最新的 N 条
    case count
    /// 只保留最近 N 天内的记录
    case days

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .count: return L("按条数")
        case .days: return L("按时间")
        }
    }
}
