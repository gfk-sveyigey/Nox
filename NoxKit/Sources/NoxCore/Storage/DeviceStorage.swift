import Foundation

/// 整机储存空间与目录占用统计。
///
/// 统一放在 Core：下载调度、储存设置页和启动保护都需要同一套口径，
/// 避免各页面用不同 API 算出不一致的数字。
public enum DeviceStorage {
    public struct Usage: Equatable, Sendable {
        public let totalBytes: Int64
        public let freeBytes: Int64

        public init(totalBytes: Int64, freeBytes: Int64) {
            self.totalBytes = max(totalBytes, 0)
            self.freeBytes = max(freeBytes, 0)
        }

        /// 已被整机使用的空间（包含系统、其他 App 和 Nox）。
        public var usedBytes: Int64 {
            max(totalBytes - freeBytes, 0)
        }
    }

    /// 当前设备数据卷的总容量 / 可用容量。
    ///
    /// `attributesOfFileSystem` 在真机和模拟器上都可用；`systemFreeSize`
    /// 对下载保护来说足够保守，宁可提前暂停，也不要把设备写满。
    public static func usage() -> Usage {
        let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )

        let total = (attributes?[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return Usage(totalBytes: total, freeBytes: free)
    }

    /// 递归统计目录内普通文件的字节数。目录不存在时返回 0。
    public static func directorySize(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
