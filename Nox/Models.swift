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
        let q = quality.isEmpty ? L("未知清晰度") : quality
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
        case .ask: return L("每次询问")
        case .best: return L("最佳")
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
    /// 用户选定的文件名（含扩展名）。nil = 用 title-quality.ext 自动生成。
    /// 便于把用户的选择带进 `assemble` / `finishHLS`，避免在列表里再查一遍。
    var desiredFilename: String?
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
    /// 分片数量。分片边界 = f(总大小, 固定分片长度)，与线程数无关，
    /// 因此这个值同时充当「分片布局是否变化」的校验位：对不上就整批作废重来。
    var segmentCount: Int?
    /// 实际使用的并发数（普通下载 = 同时在飞的分片数，m3u8 = 分片并发）。
    /// 仅用于在下载列表里如实展示「这个任务开了几条连接」，不参与续传计算。
    var threadCount: Int?

    init(id: UUID = UUID(), title: String, quality: String, format: String, sourceURL: URL,
         refererURL: URL? = nil, cookieHeader: String? = nil, desiredFilename: String? = nil,
         fileName: String? = nil, fileURL: URL? = nil, status: DownloadStatus = .queued,
         progress: Double = 0, createdAt: Date = .now, errorMessage: String? = nil,
         totalBytes: Int64? = nil, receivedBytes: Int64? = nil, segmentCount: Int? = nil,
         threadCount: Int? = nil) {
        self.id = id
        self.title = title
        self.quality = quality
        self.format = format
        self.sourceURL = sourceURL
        self.refererURL = refererURL
        self.cookieHeader = cookieHeader
        self.desiredFilename = desiredFilename
        self.fileName = fileName
        self.fileURL = fileURL
        self.status = status
        self.progress = progress
        self.createdAt = createdAt
        self.errorMessage = errorMessage
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.segmentCount = segmentCount
        self.threadCount = threadCount
    }

    /// 列表里展示的文件名。
    ///
    /// - 已完成 → 实际落盘名（可能带 " (2)" 去重后缀）
    /// - 进行中 / 排队 → 用户选定的名字
    /// - 老数据（没选过名）→ 按 `title-quality.ext` 推导，与自动命名规则一致
    var displayFilename: String {
        if let fileName, !fileName.isEmpty { return fileName }
        if let desiredFilename, !desiredFilename.isEmpty { return desiredFilename }

        let lowered = format.lowercased()
        let suffix = (lowered.isEmpty || lowered == "m3u8") ? "mp4" : lowered
        return "\(title)-\(quality).\(suffix)"
    }

    /// 历史记录里用的标题：文件名去掉扩展名。
    var displayTitle: String {
        let stem = (displayFilename as NSString).deletingPathExtension
        return stem.isEmpty ? displayFilename : stem
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
        return String(format: L("%@ %@/s"), number, Self.unitLabel(unitKey))
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
        case "GB": return L("GB")
        case "MB": return L("MB")
        case "KB": return L("KB")
        default: return L("B")
        }
    }
}

struct HistoryItem: Identifiable, Codable {
    let id: UUID
    let title: String
    let url: URL
    let visitedAt: Date
}

extension URL {
    /// 常见的跟踪参数：同一页面往往带不同的一串，逐字比较会误判成不同页。
    private static let trackingParameterNames: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "gclid", "msclkid", "igshid", "spm_id_from", "vd_source",
        "from_spmid", "share_source", "share_medium", "share_plat", "share_tag",
        "timestamp", "unique_k", "buvid"
    ]

    /// 「是否同一个页面」的归一化判定键。
    ///
    /// 大小写统一、去掉结尾斜杠与 fragment、剔除跟踪参数、参数名排序 ——
    /// 让 `https://a.com/v/` 与 `https://A.com/v?utm_source=x` 归为同一条。
    var pageIdentity: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }

        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        // path 是 String（不是 String?），所以只能用普通变量接，不能写 `if var path = ...`
        var path = components.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
            components.path = path
        }

        if let items = components.queryItems {
            let kept = items
                .filter { !Self.trackingParameterNames.contains($0.name.lowercased()) }
                .sorted {
                    $0.name == $1.name
                        ? ($0.value ?? "") < ($1.value ?? "")
                        : $0.name < $1.name
                }

            components.queryItems = kept.isEmpty ? nil : kept
        }

        return components.string ?? absoluteString
    }
}

struct ParsedVideo: Identifiable {
    let id = UUID()
    let title: String
    let pageURL: URL
    let variants: [VideoVariant]
}