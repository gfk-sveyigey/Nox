import Foundation
import CommonCrypto
import NoxCore
import NoxKeepAlive

final class HLSDownloader {
    /// 系统下载模式下，把分片请求交给后台 URLSession，并带上可恢复的分片编号。
    typealias SegmentLoader = @Sendable (URLRequest, UUID, Int, String) async throws -> Data

    struct Progress {
        let completed: Int
        let total: Int
        let bytes: Int64
        /// 按已完成分片的平均大小估算的总字节数；0 表示还无法估算。
        let estimatedTotalBytes: Int64

        init(
            completed: Int,
            total: Int,
            bytes: Int64,
            estimatedTotalBytes: Int64 = 0
        ) {
            self.completed = completed
            self.total = total
            self.bytes = bytes
            self.estimatedTotalBytes = estimatedTotalBytes
        }
    }

    /// 分片目录里的清单签名文件名
    private static let signatureFileName = "manifest.sig"

    /// HLS 没有总字节数；按「已完成分片的平均大小 × 总片数」估算，
    /// 首片完成后即可显示，越接近结束越准。
    private static func estimatedTotalBytes(
        completed: Int,
        total: Int,
        bytes: Int64
    ) -> Int64 {
        guard completed > 0, total > 0, bytes > 0 else { return 0 }
        let estimate = Double(bytes) * Double(total) / Double(completed)
        return max(bytes, Int64(estimate.rounded()))
    }

    private let concurrency: Int
    private let timeout: TimeInterval
    private let maxRetries: Int
    /// 「仅无线局域网」时置为 false，清单 / 密钥 / 分片请求都不走蜂窝。
    private let allowsCellularAccess: Bool
    /// 非 nil 时，分片请求走后台 URLSession；清单和密钥仍用普通请求。
    private let segmentLoader: SegmentLoader?

    init(
        concurrency: Int = 4,
        timeout: TimeInterval = 30,
        maxRetries: Int = 2,
        allowsCellularAccess: Bool = true,
        segmentLoader: SegmentLoader? = nil
    ) {
        self.concurrency = max(1, concurrency)
        self.timeout = timeout
        self.maxRetries = max(0, maxRetries)
        self.allowsCellularAccess = allowsCellularAccess
        self.segmentLoader = segmentLoader
    }

    /// - Returns: 合并完成的暂存文件 URL，由调用方搬到 `Documents/`
    func download(
        recordID: UUID,
        playlistURL: URL,
        referer: URL?,
        cookieHeader: String?,
        userAgent: String?,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        let fileManager = FileManager.default
        // 捕获成局部值：分片下载在 @Sendable 闭包里执行，
        // 直接读实例属性会让闭包间接捕获整个 HLSDownloader。
        let allowsCellularAccess = self.allowsCellularAccess
        let segmentLoader = self.segmentLoader
        let partsDirectory = DownloadStorage.partsDirectory(for: recordID)
        let stagingDirectory = DownloadStorage.stagingDirectory(for: recordID)

        // 注意：这里不再清空分片目录 —— 那是断点续传的前提。
        // 是否保留旧分片由下面的「清单签名」决定。
        try fileManager.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        try Task.checkCancellation()

        // 1) master 清单按码率选择子流，最多下钻 3 层
        var playlist = try await loadPlaylist(
            url: playlistURL,
            referer: referer,
            cookieHeader: cookieHeader,
            userAgent: userAgent
        )

        var depth = 0

        while playlist.isMaster, depth < 3 {
            guard let selected = playlist.variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw ParserError.invalidManifest
            }

            playlist = try await loadPlaylist(
                url: selected.url,
                referer: referer,
                cookieHeader: cookieHeader,
                userAgent: userAgent
            )
            depth += 1
        }

        guard !playlist.isMaster else { throw ParserError.invalidManifest }
        guard !playlist.segments.isEmpty else { throw ParserError.noVideoVariants }
        guard !playlist.isLive else { throw HLSDownloaderError.liveStreamUnsupported }

        try Task.checkCancellation()

        // 2) 续传判据：签名一致才保留旧分片。
        //    同一部片子换了集数或清晰度，分片序号会对不上，硬拼出来的是损坏文件。
        let signature = Self.signature(for: playlist, playlistURL: playlistURL)
        let signatureURL = partsDirectory.appendingPathComponent(Self.signatureFileName)

        let previousSignature = try? String(contentsOf: signatureURL, encoding: .utf8)

        if previousSignature != signature {
            Self.removeContents(of: partsDirectory)
        } else {
            // 上次中断可能留下半截 .tmp，清掉；已改名的 .part 才是可信的
            Self.removeTemporaryFiles(in: partsDirectory)
        }
        try? signature.write(to: signatureURL, atomically: true, encoding: .utf8)

        // 3) 密钥
        var key: Data?

        if playlist.isEncrypted, let keyURL = playlist.keyURL {
            let method = playlist.keyMethod ?? ""
            guard method == "AES-128" else {
                throw HLSDownloaderError.unsupportedEncryption(method)
            }

            key = try await Self.fetch(
                keyURL,
                referer: referer,
                cookieHeader: cookieHeader,
                userAgent: userAgent,
                allowsCellularAccess: allowsCellularAccess,
                timeout: timeout,
                maxRetries: maxRetries
            )
        }

        try Task.checkCancellation()

        // 4) fMP4 初始化段（有就落地，合并时排第一位）
        var initPart: URL?

        if let initSegmentURL = playlist.initSegmentURL {
            let target = partsDirectory.appendingPathComponent("init.part")

            if !Self.isUsable(target) {
                try await Self.downloadSegment(
                    url: initSegmentURL,
                    key: nil,
                    iv: nil,
                    sequence: 0,
                    destination: target,
                    referer: referer,
                    cookieHeader: cookieHeader,
                    userAgent: userAgent,
                    allowsCellularAccess: allowsCellularAccess,
                    recordID: recordID,
                    segmentLoader: segmentLoader,
                    segmentIndex: -1,
                    manifestSignature: signature
                )
            } else {
                try? FileManager.default.removeItem(
                    at: DownloadStorage.hlsResponseURL(
                        recordID: recordID,
                        segmentIndex: -1,
                        manifestSignature: signature
                    )
                )
            }

            initPart = target
        }

        // 5) 扫描已落盘的分片，从断点继续
        let total = playlist.segments.count
        var resumedCount = 0
        var resumedBytes: Int64 = 0
        var pendingIndexes: [Int] = []

        for index in 0..<total {
            let partURL = Self.partURL(in: partsDirectory, index: index)

            if Self.isUsable(partURL) {
                resumedCount += 1
                resumedBytes += DownloadStorage.fileSize(at: partURL)
                try? FileManager.default.removeItem(
                    at: DownloadStorage.hlsResponseURL(
                        recordID: recordID,
                        segmentIndex: index,
                        manifestSignature: signature
                    )
                )
            } else {
                pendingIndexes.append(index)
            }
        }

        let tracker = ProgressTracker(completed: resumedCount, bytes: resumedBytes)

        // 先把「续传进度」报上去，否则进度条从 0 开始，看起来像没续上
        onProgress?(
            Progress(
                completed: resumedCount,
                total: total,
                bytes: resumedBytes,
                estimatedTotalBytes: Self.estimatedTotalBytes(
                    completed: resumedCount,
                    total: total,
                    bytes: resumedBytes
                )
            )
        )

        if !pendingIndexes.isEmpty {
            try await withThrowingTaskGroup(of: Int64.self) { group in
                var cursor = 0

                func addNextTask() {
                    guard cursor < pendingIndexes.count else { return }

                    let index = pendingIndexes[cursor]
                    cursor += 1

                    let segment = playlist.segments[index]
                    let destination = Self.partURL(in: partsDirectory, index: index)

                    group.addTask {
                        try Task.checkCancellation()

                        return try await Self.downloadSegment(
                            url: segment.url,
                            key: key,
                            iv: playlist.keyIV,
                            sequence: segment.sequence,
                            destination: destination,
                            referer: referer,
                            cookieHeader: cookieHeader,
                            userAgent: userAgent,
                            allowsCellularAccess: allowsCellularAccess,
                            recordID: recordID,
                            segmentLoader: segmentLoader,
                            segmentIndex: index,
                            manifestSignature: signature
                        )
                    }
                }

                for _ in 0..<min(concurrency, pendingIndexes.count) {
                    addNextTask()
                }

                while let bytes = try await group.next() {
                    let snapshot = await tracker.advance(bytes: bytes)
                    onProgress?(
                        Progress(
                            completed: snapshot.completed,
                            total: total,
                            bytes: snapshot.bytes,
                            estimatedTotalBytes: Self.estimatedTotalBytes(
                                completed: snapshot.completed,
                                total: total,
                                bytes: snapshot.bytes
                            )
                        )
                    )

                    addNextTask()
                }
            }
        }

        try Task.checkCancellation()

        // 6) 顺序合并（不把整部片子读进内存）
        var orderedParts: [URL] = []
        if let initPart { orderedParts.append(initPart) }
        orderedParts.append(contentsOf: (0..<total).map { Self.partURL(in: partsDirectory, index: $0) })

        let merged = stagingDirectory.appendingPathComponent("merged.mp4")

        let grace = await BackgroundExecutionGrace.shared.begin(reason: "HLS 合并")
        defer {
            if let grace {
                Task { @MainActor in
                    BackgroundExecutionGrace.shared.end(grace, reason: "HLS 合并")
                }
            }
        }

        // 暂停 / 重试后旧 run 的合并可能还没退出；排队后再写，避免两个
        // FileHandle 同时改 merged.mp4。
        await DownloadStorage.MergeGate.shared.acquire("merge-\(recordID.uuidString)")
        defer { DownloadStorage.MergeGate.shared.release("merge-\(recordID.uuidString)") }

        try Task.checkCancellation()

        let identity = "hls-\(signature)-\(total)-\(initPart != nil)"
        try await Task.detached(priority: .utility) {
            try DownloadStorage.concatenate(
                orderedParts,
                into: merged,
                resumableIdentity: identity
            )
        }.value

        // 分片目录由 finishHLS 在确认写入成品后统一清理：
        // 旧 run 在这里删会把新 run 正在续传的分片一起删掉。
        return merged
    }

    // MARK: - 续传辅助

    /// 完整清单签名；清单变化时旧分片与合并检查点不再复用。
    private static func signature(for playlist: HLSPlaylist, playlistURL: URL) -> String {
        let value = ([
            playlistURL.absoluteString,
            playlist.keyURL?.absoluteString ?? "-",
            playlist.initSegmentURL?.absoluteString ?? "-",
            playlist.keyMethod ?? "-"
        ] + playlist.segments.map { "\($0.sequence)|\($0.url.absoluteString)" })
            .joined(separator: "\n")
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 分片存在且非空即视为已完成 —— 依赖「先写 .tmp 再原子改名」的写入策略。
    private static func isUsable(_ url: URL) -> Bool {
        DownloadStorage.fileSize(at: url) > 0
    }

    private static func removeContents(of directory: URL) {
        let fileManager = FileManager.default

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries {
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func removeTemporaryFiles(in directory: URL) {
        let fileManager = FileManager.default

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries where entry.pathExtension == "tmp" {
            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: - 清单 / 选流

    private func loadPlaylist(
        url: URL,
        referer: URL?,
        cookieHeader: String?,
        userAgent: String?
    ) async throws -> HLSPlaylist {
        let data = try await Self.fetch(
            url,
            referer: referer,
            cookieHeader: cookieHeader,
            userAgent: userAgent,
            allowsCellularAccess: allowsCellularAccess,
            timeout: timeout,
            maxRetries: maxRetries
        )

        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ParserError.invalidManifest
        }

        return HLSPlaylist.parse(text, baseURL: url.deletingLastPathComponent())
    }

    // MARK: - 网络

    private static func fetch(
        _ url: URL,
        referer: URL?,
        cookieHeader: String?,
        userAgent: String?,
        allowsCellularAccess: Bool,
        timeout: TimeInterval,
        maxRetries: Int
    ) async throws -> Data {
        var lastError: Error = ParserError.manifestRequestFailed(L("请求失败"))

        for attempt in 0...maxRetries {
            // 被取消时立刻退出，不要白等 sleep 与后续重试
            if Task.isCancelled { throw CancellationError() }

            do {
                guard let data = try await performFetch(
                    url,
                    referer: referer,
                    cookieHeader: cookieHeader,
                    userAgent: userAgent,
                    allowsCellularAccess: allowsCellularAccess,
                    timeout: timeout
                ) else {
                    throw ParserError.manifestRequestFailed(L("响应为空"))
                }

                return data
            } catch {
                if Task.isCancelled { throw CancellationError() }

                lastError = error

                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(400_000_000 * UInt64(attempt + 1)))
                }
            }
        }

        throw lastError
    }

    private static func performFetch(
        _ url: URL,
        referer: URL?,
        cookieHeader: String?,
        userAgent: String?,
        allowsCellularAccess: Bool,
        timeout: TimeInterval,
        recordID: UUID? = nil,
        segmentLoader: SegmentLoader? = nil,
        segmentIndex: Int = -1,
        manifestSignature: String = ""
    ) async throws -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.allowsCellularAccess = allowsCellularAccess
        request.setValue(
            "application/vnd.apple.mpegurl, application/x-mpegURL, video/*, */*;q=0.8",
            forHTTPHeaderField: "Accept"
        )

        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        if let cookieHeader, !cookieHeader.isEmpty { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if let userAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }

        if let segmentLoader {
            guard let recordID else {
                throw ParserError.manifestRequestFailed(L("HLS 分片缺少下载任务标识"))
            }
            return try await segmentLoader(request, recordID, segmentIndex, manifestSignature)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParserError.manifestRequestFailed("HTTP \(http.statusCode)")
        }

        return data
    }

    private static func downloadSegment(
        url: URL,
        key: Data?,
        iv: Data?,
        sequence: Int,
        destination: URL,
        referer: URL?,
        cookieHeader: String?,
        userAgent: String?,
        allowsCellularAccess: Bool,
        recordID: UUID,
        segmentLoader: SegmentLoader?,
        segmentIndex: Int,
        manifestSignature: String
    ) async throws -> Int64 {
        var lastError: Error = ParserError.manifestRequestFailed(L("分片下载失败"))
        let attempts = 2

        for attempt in 0...attempts {
            if Task.isCancelled { throw CancellationError() }

            do {
                let responseURL = DownloadStorage.hlsResponseURL(
                    recordID: recordID,
                    segmentIndex: segmentIndex,
                    manifestSignature: manifestSignature
                )
                let data: Data
                if let segmentLoader, let recovered = try? Data(contentsOf: responseURL) {
                    data = recovered
                } else if let fetched = try await performFetch(
                    url,
                    referer: referer,
                    cookieHeader: cookieHeader,
                    userAgent: userAgent,
                    allowsCellularAccess: allowsCellularAccess,
                    timeout: 45,
                    recordID: recordID,
                    segmentLoader: segmentLoader,
                    segmentIndex: segmentIndex,
                    manifestSignature: manifestSignature
                ) {
                    data = fetched
                } else {
                    throw ParserError.manifestRequestFailed(L("分片响应为空"))
                }

                let payload: Data
                if let key {
                    let useIV = iv ?? HLSCrypto.defaultIV(sequence: sequence)
                    payload = try HLSCrypto.decrypt(data, key: key, iv: useIV)
                } else {
                    payload = data
                }

                try Task.checkCancellation()

                // 先写临时文件再原子改名：中途被杀只会留下 .tmp，
                // 不会被下次运行误判成「已完成的分片」。
                let temporary = destination.appendingPathExtension("tmp")

                try? FileManager.default.removeItem(at: temporary)
                try payload.write(to: temporary, options: .atomic)

                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                if segmentLoader != nil {
                    try? FileManager.default.removeItem(at: responseURL)
                }

                return Int64(payload.count)
            } catch {
                if Task.isCancelled { throw CancellationError() }

                lastError = error
                if segmentLoader != nil {
                    try? FileManager.default.removeItem(
                        at: DownloadStorage.hlsResponseURL(
                            recordID: recordID,
                            segmentIndex: segmentIndex,
                            manifestSignature: manifestSignature
                        )
                    )
                }

                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(500_000_000 * UInt64(attempt + 1)))
                }
            }
        }

        throw lastError
    }

    private static func partURL(in directory: URL, index: Int) -> URL {
        directory.appendingPathComponent(String(format: "segment-%06d.part", index))
    }
}

/// 并发任务的进度计数。用 actor 而不是 `var` + 锁，避免捕获可变状态。
private actor ProgressTracker {
    private var completed: Int
    private var bytes: Int64

    init(completed: Int = 0, bytes: Int64 = 0) {
        self.completed = completed
        self.bytes = bytes
    }

    func advance(bytes delta: Int64) -> (completed: Int, bytes: Int64) {
        completed += 1
        bytes += max(delta, 0)
        return (completed, bytes)
    }

}
