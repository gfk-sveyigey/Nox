import Foundation
import WebKit

/// 下载相关的文件落盘位置。刻意做成非 actor 隔离的枚举，
/// 这样 URLSession 的 nonisolated 回调里也能安全访问。
public enum DownloadStorage {
    /// 与 NoxShare 共享的 App Group 标识。
    public static let appGroupIdentifier = "group.com.aholic.nox"

    /// Application Support 根目录。
    public static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// 分片、暂存等中间数据放 Application Support（用户不可见，也不会被系统当缓存清理）
    public static var rootDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Nox", isDirectory: true)
    }

    public static var partsRoot: URL {
        rootDirectory.appendingPathComponent("Parts", isDirectory: true)
    }

    public static var stagingRoot: URL {
        rootDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    public static var pluginsDirectory: URL {
        rootDirectory.appendingPathComponent("Plugins", isDirectory: true)
    }

    public static var logFileURL: URL {
        rootDirectory.appendingPathComponent("Nox.log")
    }

    public static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 文件 App 在 App 的 Documents 里创建的「最近删除」目录。
    ///
    /// 不同 iOS 版本 / 文件系统里大小写并不固定（见过 `.trash` 与 `.Trash`），
    /// 因此按不区分大小写的方式查找。该目录不参与下载记录，内容可安全清理。
    public static var trashDirectories: [URL] {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        return entries.filter { url in
            guard url.lastPathComponent.caseInsensitiveCompare(".trash") == .orderedSame else {
                return false
            }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    public static var libraryDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    public static var preferencesDirectory: URL {
        libraryDirectory.appendingPathComponent("Preferences", isDirectory: true)
    }

    public static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
    }

    /// 分享扩展使用的 App Group 容器；未签名 App Group 时返回 nil。
    public static var sharedContainerDirectory: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
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
        libraryDirectory.appendingPathComponent("WebKit", isDirectory: true)
    }

    /// 系统在 `Library` 根目录下创建的「用户托管资源」暂存目录。
    ///
    /// 通过系统文件选择器、分享扩展等方式把用户选中的文件交给 App 时，
    /// iOS 可能先把文件复制到 `Library/com.apple.UserManagedAssets.<随机后缀>`，
    /// 再把副本交给 App。它们本质上是缓存，但因为不在 `Library/Caches` 下，
    /// 系统不保证会自动清理，可能长期占用空间。
    public static var userManagedAssetDirectories: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: libraryDirectory.path
        )) ?? []

        return names
            .filter { $0.hasPrefix("com.apple.UserManagedAssets.") }
            .map { libraryDirectory.appendingPathComponent($0, isDirectory: true) }
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

    public static func hlsResponseURL(
        recordID: UUID,
        segmentIndex: Int,
        manifestSignature: String
    ) -> URL {
        partsDirectory(for: recordID)
            .appendingPathComponent(
                "response-\(manifestSignature)-\(String(format: "%06d", segmentIndex)).raw"
            )
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

    /// 清掉很久以前中断的合并留下的临时文件。
    ///
    /// 合并过程被系统结束后，`merged-<UUID>.tmp` 会留在暂存目录里；同一个
    /// 下载任务重试时会再生成一份。长时间、多次中断的任务因此会叠出好几份
    /// 接近成品大小的临时文件，最后真的把空间吃光、再也合不出来。
    ///
    /// 只删 30 分钟以前的：正在进行的合并不会跑这么久，活跃任务不受影响。
    public static func removeStaleMergeTemps(
        in directory: URL,
        olderThan age: TimeInterval = 30 * 60
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-age)

        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("merged-"), url.pathExtension == "tmp" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard (modified ?? .distantPast) < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// 合并进度检查点。
    ///
    /// 记录「已按顺序复制到第几个分片、目标文件写到多少字节」。进程在合并中途
    /// 被系统结束时，下次可以从这里继续，而不是把整部片子重新拷贝一遍。
    public struct MergeCheckpoint: Codable {
        /// 输入是否还是同一批分片；不一致就作废重来，避免把不同任务的数据拼在一起。
        public var identity: String
        public var partIndex: Int
        public var offset: Int64

        public init(identity: String, partIndex: Int, offset: Int64) {
            self.identity = identity
            self.partIndex = partIndex
            self.offset = offset
        }
    }

    /// 同一任务的重叠合并串行化。
    ///
    /// 暂停 / 重试会让旧的合并变成「无主的任务」，但它仍在后台写临时文件；
    /// 新 run 如果同时开始合并，两个 FileHandle 会往同一个文件里写。
    /// 这里按任务 ID 排队，后到的合并等前一个退出后再开始。
    public final class MergeGate {
        public static let shared = MergeGate()

        private let lock = NSLock()
        private var busy = Set<String>()

        public func acquire(_ key: String) async {
            while true {
                lock.lock()
                let inserted = busy.insert(key).inserted
                lock.unlock()
                if inserted { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        public func release(_ key: String) {
            lock.lock()
            busy.remove(key)
            lock.unlock()
        }
    }

    /// 按顺序合并分片为最终文件。
    ///
    /// - Parameter resumableIdentity: 非 nil 时启用断点续传：检查点与目标文件
    ///   会保留在磁盘上，进程中断后再次调用会从上次的位置继续。
    public static func concatenate(
        _ parts: [URL],
        into destination: URL,
        resumableIdentity identity: String? = nil
    ) throws {
        let fileManager = FileManager.default
        let checkpointURL = identity.map { _ in mergeStateURL(for: destination) }

        if parts.count == 1, let only = parts.first {
            if let checkpointURL {
                try? fileManager.removeItem(at: checkpointURL)
            }
            try? fileManager.removeItem(at: destination)
            // 用拷贝而不是移动：分片留在原处，进程在「拼完还没搬走」时被杀
            // 也能重新来一遍，不会因为源文件已被移走而永久失败。
            try fileManager.copyItem(at: only, to: destination)
            return
        }

        var resumeIndex = 0
        var resumeOffset: Int64 = 0

        if let identity, let checkpointURL,
           let data = try? Data(contentsOf: checkpointURL),
           let state = try? JSONDecoder().decode(MergeCheckpoint.self, from: data),
           state.identity == identity,
           state.partIndex >= 0,
           state.partIndex <= parts.count,
           state.offset >= 0,
           fileManager.fileExists(atPath: destination.path),
           fileSize(at: destination) >= state.offset {
            resumeIndex = state.partIndex
            resumeOffset = state.offset
        } else {
            if let checkpointURL {
                try? fileManager.removeItem(at: checkpointURL)
            }
            try? fileManager.removeItem(at: destination)
            fileManager.createFile(atPath: destination.path, contents: nil)
        }

        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        // 上次可能刚好写到一半：截掉检查点之后的数据，避免重复内容。
        try output.truncate(atOffset: UInt64(resumeOffset))
        _ = try output.seek(toOffset: UInt64(resumeOffset))

        var offset = resumeOffset

        for index in resumeIndex..<parts.count {
            let input = try FileHandle(forReadingFrom: parts[index])
            defer { try? input.close() }

            while let chunk = try input.read(upToCount: 1 << 22), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                offset += Int64(chunk.count)
            }

            if let identity, let checkpointURL {
                let state = MergeCheckpoint(
                    identity: identity,
                    partIndex: index + 1,
                    offset: offset
                )
                if let data = try? JSONEncoder().encode(state) {
                    try? data.write(to: checkpointURL, options: .atomic)
                }
            }
        }

        // 检查点保留到调用方真正把成品移走（或删除任务）：
        // 如果进程刚好在「合并完成、还没移走」时被杀，下次可以直接复用。
    }

    private static func mergeStateURL(for destination: URL) -> URL {
        destination
            .deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".merge-state")
    }
}
