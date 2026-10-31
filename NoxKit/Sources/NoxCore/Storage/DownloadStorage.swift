import Foundation
import WebKit

/// 下载相关的文件落盘位置。刻意做成非 actor 隔离的枚举，
/// 这样 URLSession 的 nonisolated 回调里也能安全访问。
public enum DownloadStorage {
    /// 分片、暂存等中间数据放 Application Support（用户不可见，也不会被系统当缓存清理）
    public static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nox", isDirectory: true)
    }

    public static var partsRoot: URL {
        rootDirectory.appendingPathComponent("Parts", isDirectory: true)
    }

    public static var stagingRoot: URL {
        rootDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    public static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// App 沙盒的缓存目录。网络 / 接口缓存实际落在这里，
    /// 而不是 `URLCache.shared`（本 App 的请求几乎都绕开了它）。
    public static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// WebKit 的数据目录（网站数据、网页缓存落在这里）。
    ///
    /// 没有公开 API 能取到 `WKWebsiteDataStore` 的占用，只能按目录估算；
    /// 目录不存在时返回 0。
    public static var webKitDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKit", isDirectory: true)
    }

    public static func partsDirectory(for id: UUID) -> URL {
        partsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public static func stagingDirectory(for id: UUID) -> URL {
        stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public static func partName(_ index: Int) -> String {
        String(format: "segment-%06d.part", index)
    }

    public static func partURL(in directory: URL, index: Int) -> URL {
        directory.appendingPathComponent(partName(index))
    }

    public static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 已落盘的分片字节数（按分片长度封顶，避免多余字节被计入进度）
    public static func totalPartSize(segments: [DownloadSegment], in directory: URL) -> Int64 {
        segments.reduce(into: Int64(0)) { result, segment in
            let size = fileSize(at: partURL(in: directory, index: segment.index))
            result += segment.length > 0 ? min(size, segment.length) : size
        }
    }

    /// 把 URLSession 产出的临时文件追加到分片文件末尾（续传时是关键：不能覆盖）
    public static func append(_ source: URL, to destination: URL) -> Bool {
        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
            }

            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }

            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }

            _ = try output.seekToEnd()

            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }

            return true
        } catch {
            return false
        }
    }

    /// 按顺序合并分片为最终文件
    public static func concatenate(_ parts: [URL], into destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)

        if parts.count == 1, let only = parts.first {
            // 单片时直接移动，省掉一次完整拷贝
            try FileManager.default.moveItem(at: only, to: destination)
            return
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        for part in parts {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }

            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        }
    }
}
