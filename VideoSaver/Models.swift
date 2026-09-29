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
    case scriptFailed(String)

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
        case .scriptFailed(let message): return "页面脚本执行失败：\(message)"
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

/// 下载过程中的实时统计（仅内存，不持久化）。
struct TransferStats: Equatable {
    /// 已下载字节数
    var bytesReceived: Int64 = 0
    /// 总字节数；0 表示服务器未返回 Content-Length
    var totalBytes: Int64 = 0
    /// 平滑后的瞬时速度（字节/秒）
    var bytesPerSecond: Double = 0

    /// "12.4 MB / 58.7 MB"，总大小未知时只有已下载部分
    var sizeText: String {
        let received = Self.size(bytesReceived)
        guard totalBytes > 0 else { return received }
        return "\(received) / \(Self.size(totalBytes))"
    }

    var speedText: String {
        let value = max(bytesPerSecond, 0)
        if value >= 1_000_000 {
            return String(format: "%.1f MB/s", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0f KB/s", value / 1_000)
        }
        return String(format: "%.0f B/s", value)
    }

    var displayText: String {
        "\(sizeText) · \(speedText)"
    }

    private static func size(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return byteFormatter.string(fromByteCount: bytes)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.isAdaptive = false
        return formatter
    }()
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