import Foundation

/// HLS（m3u8）下载引擎。
///
/// 两条路径的能力取舍不同，由用户在下载设置里选择：
/// - `segmented`：自定义清单解析 + 分片下载 + AES-128 解密 + 合并，
///   兼容自定义 Cookie / Referer，也能输出普通 MP4；
/// - `avAsset`：交给系统的 `AVAssetDownloadURLSession`，后台调度与断点由系统接管，
///   更适合大清单和长时间后台下载，但导出需要额外转封装。
public enum HLSDownloadEngine: String, CaseIterable, Identifiable, Codable {
    case segmented
    case avAsset

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .segmented: return L("兼容分片")
        case .avAsset: return L("系统 AVAsset")
        }
    }

    public var detail: String {
        switch self {
        case .segmented:
            return L("逐片下载后合并。支持自定义请求头，输出标准 MP4；后台时间由保活方式决定。")
        case .avAsset:
            return L("交给 AVAssetDownloadURLSession 下载，后台调度由系统接管；完成后自动导出 MP4。仅对 m3u8 生效。")
        }
    }
}
