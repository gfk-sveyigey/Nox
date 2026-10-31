import Foundation

public enum LogLevel: String, CaseIterable, Identifiable {
    case info
    case warning
    case error

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .info: return L("信息")
        case .warning: return L("警告")
        case .error: return L("错误")
        }
    }
}
