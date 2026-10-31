import Foundation

public enum ParserError: LocalizedError {
    case invalidURL
    case unsupportedURL
    case pageLoadFailed(String)
    case noMediaDefinitions
    case noRemoteManifest
    case manifestRequestFailed(String)
    case invalidManifest
    case noVideoVariants
    case scriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L("请输入有效的视频页面地址。")
        case .unsupportedURL:
            return L("当前网页不符合视频解析规则。")
        case .pageLoadFailed(let message):
            return String(format: L("页面加载失败：%@"), message)
        case .noMediaDefinitions:
            return L("页面中没有找到可用的视频信息。")
        case .noRemoteManifest:
            return L("没有找到远程视频清单。")
        case .manifestRequestFailed(let message):
            return String(format: L("视频清单请求失败：%@"), message)
        case .invalidManifest:
            return L("视频清单格式无法识别。")
        case .noVideoVariants:
            return L("没有找到可下载的视频清晰度。")
        case .scriptFailed(let message):
            return String(format: L("页面脚本执行失败：%@"), message)
        }
    }
}
