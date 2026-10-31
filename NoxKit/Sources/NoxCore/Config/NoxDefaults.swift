import Foundation

/// 全 App 共享的默认值与可选范围。
///
/// 放在 Core 而不是 `AppState`：下载引擎与保活引擎都需要这些常量，
/// 但它们不应该反向依赖状态类。
public enum NoxDefaults {
    /// 可选的下载线程数范围
    public static let segmentCountRange = 1...32
    /// 多线程下载的默认线程数
    public static let defaultSegmentCount = 4
    /// 多线程下载的固定分片大小（4 MB）
    public static let segmentLength: Int64 = 4 * 1024 * 1024

    /// m3u8 分片并发数范围。0 表示跟随「多线程下载」设置
    public static let m3u8ConcurrencyRange = 0...32
    /// m3u8 分片并发数默认值：跟随「多线程下载」设置
    public static let defaultM3u8Concurrency = 0
    /// m3u8 分片并发上限。分片远小于字节分片、总数可达数百，开太大容易触发 CDN 限速
    public static let maxHLSConcurrency = 32
    /// 未开启「多线程下载」时，m3u8 使用的分片并发
    public static let defaultHLSConcurrency = 4

    /// 同时下载任务数「无限制」的取值
    public static let unlimitedConcurrentDownloads = 0
    /// 同时下载任务数的可选项（0 = 无限制）
    public static let maxConcurrentDownloadsOptions = [1, 3, 5, 10, 20, unlimitedConcurrentDownloads]
    /// 同时进行的下载任务数默认值
    public static let defaultMaxConcurrentDownloads = 3

    /// 历史保留「无限制」的取值
    public static let unlimitedHistory = 0
    /// 历史「按条数」保留的可选上限（0 = 无限制）
    public static let historyCountOptions = [20, 50, 100, 200, 500, unlimitedHistory]
    /// 历史「按条数」保留的默认上限
    public static let defaultHistoryCount = 50
    /// 历史「按时间」保留的可选天数（0 = 无限制）
    public static let historyDayOptions = [1, 3, 7, 30, 90, unlimitedHistory]
    /// 历史「按时间」保留的默认天数
    public static let defaultHistoryDays = 30

    /// 画中画窗口高度可选范围：0（最小/隐藏）… 最大可见小窗。
    public static let pipWindowHeightRange: ClosedRange<Double> = 0...225
    /// 默认最小化：不影响操作。
    public static let defaultPiPWindowHeight: Double = 0
    /// 实际布局用的最小高度：0.1pt，视觉隐藏。
    public static let minimizedPiPWindowHeight: Double = 0.1

    /// 日志保留天数默认值
    public static let defaultLogRetentionDays = 30
}
