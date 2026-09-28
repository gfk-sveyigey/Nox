import Foundation

struct VideoVariant: Identifiable, Hashable {
    let id = UUID()
    let quality: String
    let format: String
    let url: URL
}

enum ParserError: LocalizedError {
    case invalidURL
    case pageLoadFailed
    case mediaDefinitionsNotFound
    case remoteURLNotFound
    case remoteResponseInvalid
    case noVideoVariants

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的视频页面 URL"
        case .pageLoadFailed: return "视频页面加载失败"
        case .mediaDefinitionsNotFound: return "没有找到 mediaDefinitions"
        case .remoteURLNotFound: return "没有找到视频资源接口"
        case .remoteResponseInvalid: return "视频资源接口返回的数据无法解析"
        case .noVideoVariants: return "没有找到可下载的视频版本"
        }
    }
}

enum DownloadState: Equatable {
    case idle
    case downloading
    case completed(URL)
    case failed(String)
}
