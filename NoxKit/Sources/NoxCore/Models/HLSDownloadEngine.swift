import Foundation

/// HLS（m3u8）下载引擎。
///
/// 不再由用户单独选择，而是跟随「后台方式」自动决定：
/// - `segmented`：自定义清单解析 + 分片下载 + AES-128 解密 + 合并，
///   兼容自定义 Cookie / Referer，也能输出普通 MP4；
/// - `avAsset`：交给系统的 `AVAssetDownloadURLSession`，后台调度与断点由系统接管。
///
/// AVAsset 只有在 iOS 26 及以上才提供字节统计所需的 metric event；低版本
/// 无法显示总大小和速度，因此自动回落到分片引擎。
public enum HLSDownloadEngine: String {
    case segmented
    case avAsset

    public var isAvailable: Bool {
        switch self {
        case .segmented: return true
        case .avAsset:
            if #available(iOS 26.0, *) { return true }
            return false
        }
    }
}
