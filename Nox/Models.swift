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
        let q = quality.isEmpty ? String(localized: "未知清晰度") : quality
        let f = format.isEmpty ? "VIDEO" : format.uppercased()
        return "\(q) · \(f)"
    }
}

/// 下载清晰度偏好。
/// 用稳定代码（rawValue）持久化，而不是本地化后的标题，
/// 这样切换系统语言后已保存的设置不会失效。
enum PreferredQuality: String, CaseIterable, Identifiable {
    case ask
    case best
    case p1080
    case p720
    case p480
    case p360

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return String(localized: "每次询问")
        case .best: return String(localized: "最佳")
        case .p1080: return "1080P"
        case .p720: return "720P"
        case .p480: return "480P"
        case .p360: return "360P"
        }
    }

    /// 期望的清晰度数值；`.ask` / `.best` 返回 0
    var qualityNumber: Int {
        Int(rawValue.filter(\.isNumber)) ?? 0
    }

    /// 兼容旧版本（直接存了中文/英文标题）的已保存值
    static func migrated(from raw: String?) -> PreferredQuality {
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
        case .invalidURL:
            return String(localized: "请输入有效的视频页面地址。")
        case .unsupportedURL:
            return String(localized: "当前网页不符合视频解析规则。")
        case .pageLoadFailed(let message):
            return String(localized: "页面加载失败：\(message)")
        case .noMediaDefinitions:
            return String(localized: "页面中没有找到可用的视频信息。")
        case .noRemoteManifest:
            return String(localized: "没有找到远程视频清单。")
        case .manifestRequestFailed(let message):
            return String(localized: "视频清单请求失败：\(message)")
        case .invalidManifest:
            return String(localized: "视频清单格式无法识别。")
        case .noVideoVariants:
            return String(localized: "没有找到可下载的视频清晰度。")
        case .scriptFailed(let message):
            return String(localized: "页面脚本执行失败：\(message)")
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

    // MARK: - 断点续传 / 多线程下载

    /// 远端文件总大小；未知为 nil。用于计算分片边界与进度。
    var totalBytes: Int64?
    /// 已写入磁盘（分片文件）的字节数，用于暂停后展示进度。
    var receivedBytes: Int64?
    /// 上次使用的分片数量。续传时必须沿用同一数量，否则分片边界会错位。
    var segmentCount: Int?

    init(id: UUID = UUID(), title: String, quality: String, format: String, sourceURL: URL,
         refererURL: URL? = nil, cookieHeader: String? = nil, fileName: String? = nil,
         fileURL: URL? = nil, status: DownloadStatus = .queued, progress: Double = 0,
         createdAt: Date = .now, errorMessage: String? = nil,
         totalBytes: Int64? = nil, receivedBytes: Int64? = nil, segmentCount: Int? = nil) {
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
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.segmentCount = segmentCount
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
    /// 总字节数；0 表示服务器未返回总大小
    var totalBytes: Int64 = 0
    /// 平滑后的瞬时速度（字节/秒）
    var bytesPerSecond: Double = 0

    /// "12.4 MB / 58.7 MB"，总大小未知时只有已下载部分
    var sizeText: String {
        let received = Self.formattedSize(bytesReceived)
        guard totalBytes > 0 else { return received }
        return "\(received) / \(Self.formattedSize(totalBytes))"
    }

    var speedText: String {
        let value = max(bytesPerSecond, 0)

        let scaled: Double
        let unitKey: String

        if value >= 1_000_000_000 {
            scaled = value / 1_000_000_000
            unitKey = "GB"
        } else if value >= 1_000_000 {
            scaled = value / 1_000_000
            unitKey = "MB"
        } else if value >= 1_000 {
            scaled = value / 1_000
            unitKey = "KB"
        } else {
            scaled = value
            unitKey = "B"
        }

        let number = Self.decimal(scaled, maximumFractionDigits: scaled >= 100 ? 0 : 1)
        return String(format: String(localized: "%@ %@/s"), number, Self.unitLabel(unitKey))
    }

    var displayText: String {
        "\(sizeText) · \(speedText)"
    }

    /// 供其它视图复用的大小格式化（例如「已下载 12.4 MB」）
    static func formattedSize(_ bytes: Int64) -> String {
        let value = max(bytes, 0)

        let scaled: Double
        let unitKey: String

        if value >= 1_000_000_000 {
            scaled = Double(value) / 1_000_000_000
            unitKey = "GB"
        } else if value >= 1_000_000 {
            scaled = Double(value) / 1_000_000
            unitKey = "MB"
        } else if value >= 1_000 {
            scaled = Double(value) / 1_000
            unitKey = "KB"
        } else {
            scaled = Double(value)
            unitKey = "B"
        }

        let number = decimal(scaled, maximumFractionDigits: scaled >= 100 ? 0 : 1)
        return "\(number) \(unitLabel(unitKey))"
    }

    /// 按 App 语言格式化数字，保证小数点/千分位符合该语言习惯（fr 用 "1,5"）
    private static func decimal(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = AppLocale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%.\(maximumFractionDigits)f", value)
    }

    /// 用 switch 而不是动态拼 key，避免依赖不稳定的 API
    private static func unitLabel(_ key: String) -> String {
        switch key {
        case "GB": return String(localized: "GB")
        case "MB": return String(localized: "MB")
        case "KB": return String(localized: "KB")
        default: return String(localized: "B")
        }
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