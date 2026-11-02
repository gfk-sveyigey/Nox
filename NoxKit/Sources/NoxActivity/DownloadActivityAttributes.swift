import ActivityKit
import Foundation

/// 下载 Live Activity 的静态属性。
///
/// 只放整个活动生命周期内不会变化的内容；进度、速度、当前任务等放在
/// `ContentState` 里，避免每次刷新都重建活动。
public struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 0...1 的总进度。
        public var progress: Double
        /// 排队中 + 下载中的任务数。
        public var activeCount: Int
        /// 其中真正在下载的任务数。
        public var downloadingCount: Int
        /// 所有活跃任务的合计速度（字节/秒）。
        public var bytesPerSecond: Double
        /// 当前主要任务的标题。
        public var currentTitle: String
        /// 内容生成时间，便于界面判断是否过旧。
        public var updatedAt: Date

        public init(
            progress: Double,
            activeCount: Int,
            downloadingCount: Int,
            bytesPerSecond: Double,
            currentTitle: String,
            updatedAt: Date = .now
        ) {
            self.progress = min(max(progress, 0), 1)
            self.activeCount = max(activeCount, 0)
            self.downloadingCount = max(downloadingCount, 0)
            self.bytesPerSecond = max(bytesPerSecond, 0)
            self.currentTitle = currentTitle
            self.updatedAt = updatedAt
        }
    }

    /// 活动开始时间。用于排序和界面展示。
    public var startedAt: Date

    public init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }
}

/// Live Activity 点击后回到 App 下载页的深链。
public enum DownloadActivityLink {
    public static let url = URL(string: "nox://downloads")!
}
