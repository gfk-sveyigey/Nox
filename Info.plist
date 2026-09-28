import Foundation

struct VideoVariant: Identifiable, Codable, Hashable {
    let id: UUID
    let quality: String
    let format: String
    let url: URL

    init(id: UUID = UUID(), quality: String, format: String, url: URL) {
        self.id = id
        self.quality = quality
        self.format = format
        self.url = url
    }

    var displayName: String {
        let q = quality.isEmpty ? "未知清晰度" : quality
        let f = format.isEmpty ? "VIDEO" : format.uppercased()
        return "\(q) · \(f)"
    }
}

enum ParserError: LocalizedError {
    case invalidURL
    case unsupportedURL
    case pageLoadFailed(String)
    case noMediaDefinitions
    case noRemoteManifest
    case manifestRequestFailed(String)
    case invalidManifest
    case noVideoVariants

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的视频页面地址。"
        case .unsupportedURL: return "当前网页不符合视频解析规则。"
        case .pageLoadFailed(let message): return "页面加载失败：\(message)"
        case .noMediaDefinitions: return "页面中没有找到可用的视频信息。"
        case .noRemoteManifest: return "没有找到远程视频清单。"
        case .manifestRequestFailed(let message): return "视频清单请求失败：\(message)"
        case .invalidManifest: return "视频清单格式无法识别。"
        case .noVideoVariants: return "没有找到可下载的视频清晰度。"
        }
    }
}

enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case finished
    case failed
    case cancelled
}

struct DownloadRecord: Identifiable, Codable {
    let id: UUID
    let title: String
    let quality: String
    let format: String
    let sourceURL: URL
    var refererURL: URL?
    var cookieHeader: String?
    /// 仅文件名（相对 Documents）。沙盒容器路径会随重装/更新变化，不能持久化绝对路径。
    var fileName: String?
    /// 兼容旧数据：新写入仅作参考，读取时一律以 Documents + 文件名为准。
    var fileURL: URL?
    var status: DownloadStatus
    var progress: Double
    var createdAt: Date
    var errorMessage: String?

    init(id: UUID = UUID(), title: String, quality: String, format: String, sourceURL: URL,
         refererURL: URL? = nil, cookieHeader: String? = nil, fileName: String? = nil,
         fileURL: URL? = nil, status: DownloadStatus = .queued, progress: Double = 0,
         createdAt: Date = .now, errorMessage: String? = nil) {
        self.id = id
        self.title = title
        self.quality = quality
        self.format = format
        self.sourceURL = sourceURL
        self.refererURL = refererURL
        self.cookieHeader = cookieHeader
        self.fileName = fileName
        self.fileURL = fileURL
        self.status = status
        self.progress = progress
        self.createdAt = createdAt
        self.errorMessage = errorMessage
    }

    /// 用于长按菜单判断是否显示「分享」。
    var hasLocalFile: Bool {
        fileName != nil || fileURL != nil
    }
}

struct HistoryItem: Identifiable, Codable {
    let id: UUID
    let title: String
    let url: URL
    let visitedAt: Date
}

struct ParsedVideo: Identifiable {
    let id = UUID()
    let title: String
    let pageURL: URL
    let variants: [VideoVariant]
}