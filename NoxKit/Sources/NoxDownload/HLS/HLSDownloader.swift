import Foundation
import CommonCrypto
import NoxCore

final class HLSDownloader {
    struct Progress {
        let completed: Int
        let total: Int
        let bytes: Int64
    }

    /// 分片目录里的清单签名文件名
    private static let signatureFileName = "manifest.sig"

    private let concurrency: Int
    private let timeout: TimeInterval
    private let maxRetries: Int
    /// 「仅无线局域网」时置为 false，清单 / 密钥 / 分片请求都不走蜂窝。
    private let allowsCellularAccess: Bool

    init(
        concurrency: Int = 4,
        timeout: TimeInterval = 30,
        maxRetries: Int = 2,
        allowsCellularAccess: Bool = true
    ) {
        self.concurrency = max(1, concurrency)
        self.timeout = timeout
        self.maxRetries = max(0, maxRetries)
        self.allowsCellularAccess = allowsCellularAccess
    }

    /// - Returns: 合并完成的暂存文件 URL，由调用方搬到 `Documents/`
    func download(
        recordID: UUID,
        playlistURL: URL,
        referer: URL?,
        cookieHeader: String?,
        userAgent: String?,
        quality: PreferredQuality,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        let fileManager = FileManager.default
        // 捕获成局部值：分片下载在 @Sendable 闭包里执行，
        // 直接读实例属性会让闭包间接捕获整个 HLSDownloader。
        let allowsCellularAccess = self.allowsCellularAccess
        let partsDirectory = DownloadStorage.partsDirectory(for: recordID)
        let stagingDirectory = DownloadStorage.stagingDirectory(for: recordID)

        // 注意：这里不再清空分片目录 —— 那是断点续传的前提。
        // 是否保留旧分片由下面的「清单签名」决定。
        try fileManager.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        try Task.checkCancellation()

        // 1) 清单：master 时按偏好挑子流，最多下钻 3 层
        var playlist = try await loadPlaylist(
            url: playlistURL,
            referer: referer,
            cookieHeader: cookieHeader,
            userAgent: userAgent
        )

        var depth = 0

        while playlist.isMaster, depth < 3 {
            guard let selected = selectVariant(from: playlist.variants, preference: quality) else {
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
            try? signature.write(to: signatureURL, atomically: true, encoding: .utf8)
        } else {
            // 上次中断可能留下半截 .tmp，清掉；已改名的 .part 才是可信的
            Self.removeTemporaryFiles(in: partsDirectory)
        }

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
                    allowsCellularAccess: allowsCellularAccess
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
            } else {
                pendingIndexes.append(index)
            }
        }

        let tracker = ProgressTracker(completed: resumedCount, bytes: resumedBytes)

        // 先把「续传进度」报上去，否则进度条从 0 开始，看起来像没续上
        onProgress?(Progress(completed: resumedCount, total: total, bytes: resumedBytes))

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
                            allowsCellularAccess: allowsCellularAccess
                        )
                    }
                }

                for _ in 0..<min(concurrency, pendingIndexes.count) {
                    addNextTask()
                }

                while let bytes = try await group.next() {
                    let snapshot = await tracker.advance(bytes: bytes)
                    onProgress?(
                        Progress(completed: snapshot.completed, total: total, bytes: snapshot.bytes)
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

        try await Task.detached(priority: .utility) {
            try DownloadStorage.concatenate(orderedParts, into: merged)
        }.value

        // 合并成功才清分片；失败时保留，下次重试可以接着下
        try? fileManager.removeItem(at: partsDirectory)

        return merged
    }

    // MARK: - 续传辅助

    /// 清单签名：清单地址 + 分片数 + 密钥与初始化段地址 + 首尾分片地址。
    /// 任一变化都说明「这不是同一份清单」，旧分片不能再拼。
    private static func signature(for playlist: HLSPlaylist, playlistURL: URL) -> String {
        [
            playlistURL.absoluteString,
            String(playlist.segments.count),
            playlist.keyURL?.absoluteString ?? "-",
            playlist.initSegmentURL?.absoluteString ?? "-",
            playlist.segments.first?.url.absoluteString ?? "-",
            playlist.segments.last?.url.absoluteString ?? "-"
        ].joined(separator: "|")
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

    private func selectVariant(
        from variants: [HLSPlaylist.Variant],
        preference: PreferredQuality
    ) -> HLSPlaylist.Variant? {
        guard !variants.isEmpty else { return nil }

        let sorted = variants.sorted { $0.bandwidth > $1.bandwidth }

        switch preference {
        case .p360, .p480, .p720, .p1080:
            let wanted = preference.qualityNumber

            // 取「不超过目标」里最高的那一档
            if let match = sorted.first(where: { variant in
                guard let height = Self.height(from: variant.resolution) else { return false }
                return height <= wanted
            }) {
                return match
            }

            return sorted.last

        case .ask, .best:
            // master 场景在下载阶段无法弹窗询问，统一取最高码率
            return sorted.first
        }
    }

    private static func height(from resolution: String?) -> Int? {
        guard let resolution else { return nil }

        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2 else { return nil }

        return Int(parts[1])
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
        var lastError: Error = ParserError.manifestRequestFailed("请求失败")

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
                    throw ParserError.manifestRequestFailed("响应为空")
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
        timeout: TimeInterval
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
        allowsCellularAccess: Bool
    ) async throws -> Int64 {
        var lastError: Error = ParserError.manifestRequestFailed("分片下载失败")
        let attempts = 2

        for attempt in 0...attempts {
            if Task.isCancelled { throw CancellationError() }

            do {
                guard let data = try await performFetch(
                    url,
                    referer: referer,
                    cookieHeader: cookieHeader,
                    userAgent: userAgent,
                    allowsCellularAccess: allowsCellularAccess,
                    timeout: 45
                ) else {
                    throw ParserError.manifestRequestFailed("分片响应为空")
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

                return Int64(payload.count)
            } catch {
                if Task.isCancelled { throw CancellationError() }

                lastError = error

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
