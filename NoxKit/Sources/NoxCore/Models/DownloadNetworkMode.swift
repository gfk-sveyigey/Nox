import Foundation

/// 下载可用的网络类型。
///
/// iOS 只提供「是否允许蜂窝网络」这一个公开开关，无法反过来强制走蜂窝，
/// 因此这里只区分「都可以」与「仅无线局域网」。
public enum DownloadNetworkMode: String, CaseIterable, Identifiable {
    /// 无线局域网与蜂窝（默认）
    case wifiAndCellular
    /// 仅无线局域网：不使用任何蜂窝流量
    case wifiOnly

    public var id: String { rawValue }

    /// 是否允许请求使用蜂窝网络。
    public var allowsCellularAccess: Bool {
        self != .wifiOnly
    }

    public var title: String {
        switch self {
        case .wifiAndCellular: return L("无线局域网与蜂窝")
        case .wifiOnly: return L("仅无线局域网")
        }
    }
}
