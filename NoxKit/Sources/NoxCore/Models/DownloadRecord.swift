import Foundation

public enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case finished
    case failed
    case cancelled
}

public struct DownloadRecord: Identifiable, Codable {
    public let id: UUID
    public let title: String
    public let quality: String
    public let format: String
    public let sourceURL: URL
    public var refererURL: URL?
    public var cookieHeader: String?
    /// 用户选定的文件名（含扩展名）。nil = 用 title-quality.ext 自动生成。
    /// 便于把用户的选择带进 `assemble` / `finishHLS`，避免在列表里再查一遍。
    public var desiredFilename: String?
    /// 仅文件名（相对 Documents）。沙盒容器路径会随重装/更新变化，不能持久化绝对路径。
    public var fileName: String?
    /// 兼容旧数据：新写入仅作参考，读取时一律以 Documents + 文件名为准。
    public var fileURL: URL?
    public var status: DownloadStatus
    public var progress: Double
    public var createdAt: Date
    public var errorMessage: String?

    // MARK: - 断点续传 / 多线程下载

    /// 远端文件总大小；未知为 nil。用于计算分片边界与进度。
    public var totalBytes: Int64?
    /// 已写入磁盘（分片文件）的字节数，用于暂停后展示进度。
    public var receivedBytes: Int64?
    /// 分片数量。分片边界 = f(总大小, 固定分片长度)，与线程数无关，
    /// 因此这个值同时充当「分片布局是否变化」的校验位：对不上就整批作废重来。
    public var segmentCount: Int?
    /// 实际使用的并发数（普通下载 = 同时在飞的分片数，m3u8 = 分片并发）。
    /// 仅用于在下载列表里如实展示「这个任务开了几条连接」，不参与续传计算。
    public var threadCount: Int?

    public init(id: UUID = UUID(), title: String, quality: String, format: String, sourceURL: URL,
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
    public var displayFilename: String {
        if let fileName, !fileName.isEmpty { return fileName }
        if let desiredFilename, !desiredFilename.isEmpty { return desiredFilename }

        let lowered = format.lowercased()
        let suffix = (lowered.isEmpty || lowered == "m3u8") ? "mp4" : lowered
        return "\(title)-\(quality).\(suffix)"
    }

    /// 历史记录里用的标题：文件名去掉扩展名。
    public var displayTitle: String {
        let stem = (displayFilename as NSString).deletingPathExtension
        return stem.isEmpty ? displayFilename : stem
    }

    /// 用于长按菜单判断是否显示「分享」。
    public var hasLocalFile: Bool {
        fileName != nil || fileURL != nil
    }
}
