import Foundation
import CommonCrypto

// MARK: - m3u8 清单

struct HLSPlaylist {
    struct Variant {
        let url: URL
        let bandwidth: Int
        let resolution: String?
    }

    struct Segment {
        let url: URL
        /// media sequence：未显式给出 IV 时，它就是 IV 的来源
        let sequence: Int
    }

    var isMaster = false
    var isLive = false
    var variants: [Variant] = []
    var segments: [Segment] = []
    var initSegmentURL: URL?
    var isEncrypted = false
    var keyMethod: String?
    var keyURL: URL?
    var keyIV: Data?
    var totalDuration: Double = 0

    static func parse(_ text: String, baseURL: URL) -> HLSPlaylist {
        var result = HLSPlaylist()
        let lines = text.components(separatedBy: .newlines)

        var pendingDuration: Double = 0
        var mediaSequence = 0
        var relativeIndex = 0
        var hasEndList = false
        var index = 0

        while index < lines.count {
            let raw = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1

            guard !raw.isEmpty else { continue }

            if raw.hasPrefix("#EXT-X-STREAM-INF:") {
                result.isMaster = true

                let info = String(raw.dropFirst("#EXT-X-STREAM-INF:".count))
                let bandwidth = attribute("BANDWIDTH", in: info).flatMap(Int.init) ?? 0
                let resolution = attribute("RESOLUTION", in: info)

                // URI 在紧随其后的第一条非注释行
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1

                    guard !candidate.isEmpty else { continue }
                    if candidate.hasPrefix("#") { continue }

                    if let url = URL(string: candidate, relativeTo: baseURL)?.absoluteURL {
                        result.variants.append(
                            Variant(url: url, bandwidth: bandwidth, resolution: resolution)
                        )
                    }
                    break
                }
                continue
            }

            if raw.hasPrefix("#EXT-X-KEY:") {
                let info = String(raw.dropFirst("#EXT-X-KEY:".count))
                let method = attribute("METHOD", in: info)?.uppercased() ?? "NONE"

                if method == "NONE" {
                    result.isEncrypted = false
                    result.keyMethod = nil
                    result.keyURL = nil
                    result.keyIV = nil
                } else {
                    result.isEncrypted = true
                    result.keyMethod = method

                    if let uri = attribute("URI", in: info),
                       let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                        result.keyURL = url
                    }

                    result.keyIV = attribute("IV", in: info).flatMap(hexToData)
                }
                continue
            }

            if raw.hasPrefix("#EXT-X-MAP:") {
                let info = String(raw.dropFirst("#EXT-X-MAP:".count))

                if let uri = attribute("URI", in: info),
                   let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                    result.initSegmentURL = url
                }
                continue
            }

            if raw.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let value = String(raw.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count))
                mediaSequence = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
                relativeIndex = 0
                continue
            }

            if raw.hasPrefix("#EXTINF:") {
                let value = String(raw.dropFirst("#EXTINF:".count))
                let number = value.split(separator: ",").first.map(String.init) ?? value
                pendingDuration = Double(number.trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }

            if raw.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
                continue
            }

            if raw.hasPrefix("#") { continue }

            // 真正的分片 URI
            if let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL {
                result.segments.append(Segment(url: url, sequence: mediaSequence + relativeIndex))
                relativeIndex += 1
                result.totalDuration += pendingDuration
                pendingDuration = 0
            }
        }

        if !result.isMaster {
            result.isLive = !hasEndList && !result.segments.isEmpty
        }

        return result
    }

    /// 解析 `KEY=VALUE`，忽略引号内的逗号（`CODECS="avc1,mp4a"` 这类值必需）
    static func attribute(_ name: String, in line: String) -> String? {
        var parts: [String] = []
        var current = ""
        var insideQuotes = false

        for character in line {
            if character == "\"" {
                insideQuotes.toggle()
                current.append(character)
                continue
            }

            if character == "," && !insideQuotes {
                parts.append(current)
                current = ""
                continue
            }

            current.append(character)
        }
        parts.append(current)

        let prefix = name + "="

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }

            return String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        return nil
    }

    static func hexToData(_ hex: String) -> Data? {
        var value = hex.lowercased()
        if value.hasPrefix("0x") { value = String(value.dropFirst(2)) }

        guard !value.isEmpty, value.count % 2 == 0 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)

        var index = value.startIndex

        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }

            bytes.append(byte)
            index = next
        }

        return Data(bytes)
    }
}

// MARK: - AES-128-CBC（对应脚本 AES.decryptCBC）

enum HLSCrypto {
    enum Failure: LocalizedError {
        case badKeyLength(Int)
        case cryptFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .badKeyLength(let count):
                return String(format: L("HLS 密钥长度错误：%d"), count)
            case .cryptFailed(let status):
                return String(format: L("HLS 解密失败（%d）"), status)
            }
        }
    }

    /// AES-128-CBC + PKCS#7。HLS 的分片正是这个组合。
    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw Failure.badKeyLength(key.count) }
        guard !data.isEmpty else { return data }

        var ivBytes = iv
        if ivBytes.count != kCCBlockSizeAES128 {
            ivBytes = Data(repeating: 0, count: kCCBlockSizeAES128)
        }

        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    ivBytes.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, key.count,
                            ivBuffer.baseAddress,
                            inputBuffer.baseAddress, data.count,
                            outputBuffer.baseAddress, outputBuffer.count,
                            &moved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { throw Failure.cryptFailed(status) }

        return output.prefix(moved)
    }

    /// 清单未显式给出 IV 时，用「分片序号」左补零成 16 字节大端。
    ///
    /// 注意：这里用的是 `EXT-X-MEDIA-SEQUENCE + 相对下标`，而不是数组下标 ——
    /// 带 `#EXT-X-MEDIA-SEQUENCE` 的流（直播、部分点播）两者不同，
    /// 用下标解出来的画面会花屏。
    static func defaultIV(sequence: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let value = UInt64(truncatingIfNeeded: sequence).bigEndian

        withUnsafeBytes(of: value) { raw in
            for (offset, byte) in raw.enumerated() {
                bytes[8 + offset] = byte
            }
        }

        return Data(bytes)
    }
}

// MARK: - 下载器

enum HLSDownloaderError: LocalizedError {
    case liveStreamUnsupported
    case unsupportedEncryption(String)

    var errorDescription: String? {
        switch self {
        case .liveStreamUnsupported:
            return L("这是直播流（没有结束标记），无法合并为文件。")
        case .unsupportedEncryption(let method):
            return String(format: L("不支持的加密方式：%@"), method)
        }
    }
}

/// m3u8 → 分片并发下载 → AES-128 解密 → 顺序合并。
///
/// 刻意不做 actor 隔离：下载逻辑本身无共享可变状态，
/// 进度计数交给 `ProgressTracker` actor，避免主线程被网络等待占住。
final class HLSDownloader {
    struct Progress {
        let completed: Int
        let total: Int
        let bytes: Int64
    }

    private let concurrency: Int
    private let timeout: TimeInterval
    private let maxRetries: Int

    init(concurrency: Int = 4, timeout: TimeInterval = 30, maxRetries: Int = 2) {
        self.concurrency = max(1, concurrency)
        self.timeout = timeout
        self.maxRetries = max(0, maxRetries)
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
        let partsDirectory = DownloadStorage.partsDirectory(for: recordID)
        let stagingDirectory = DownloadStorage.stagingDirectory(for: recordID)

        try? fileManager.removeItem(at: partsDirectory)
        try fileManager.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

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

        // 2) 密钥
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
                timeout: timeout,
                maxRetries: maxRetries
            )
        }

        // 3) fMP4 初始化段（有就先落地，合并时排第一位）
        var initPart: URL?

        if let initSegmentURL = playlist.initSegmentURL {
            let target = partsDirectory.appendingPathComponent("init.part")

            _ = try await Self.downloadSegment(
                url: initSegmentURL,
                key: nil,
                iv: nil,
                sequence: 0,
                destination: target,
                referer: referer,
                cookieHeader: cookieHeader,
                userAgent: userAgent
            )

            initPart = target
        }

        // 4) 分片并发下载 + 解密；文件名带序号，合并时按序号取
        let total = playlist.segments.count
        let tracker = ProgressTracker()

        try await withThrowingTaskGroup(of: Int64.self) { group in
            var next = 0
            let initial = min(concurrency, total)

            func addTask(_ index: Int) {
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
                        userAgent: userAgent
                    )
                }
            }

            while next < initial {
                addTask(next)
                next += 1
            }

            while let bytes = try await group.next() {
                let snapshot = await tracker.advance(bytes: bytes)
                onProgress?(Progress(completed: snapshot.completed, total: total, bytes: snapshot.bytes))

                if next < total {
                    addTask(next)
                    next += 1
                }
            }
        }

        try Task.checkCancellation()

        // 5) 顺序合并（不把整部片子读进内存）
        var orderedParts: [URL] = []
        if let initPart { orderedParts.append(initPart) }
        orderedParts.append(contentsOf: (0..<total).map { Self.partURL(in: partsDirectory, index: $0) })

        let merged = stagingDirectory.appendingPathComponent("merged.mp4")

        try await Task.detached(priority: .utility) {
            try DownloadStorage.concatenate(orderedParts, into: merged)
        }.value

        try? fileManager.removeItem(at: partsDirectory)

        return merged
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
        timeout: TimeInterval,
        maxRetries: Int
    ) async throws -> Data {
        var lastError: Error = ParserError.manifestRequestFailed("请求失败")

        for attempt in 0...maxRetries {
            do {
                guard let data = try await performFetch(
                    url,
                    referer: referer,
                    cookieHeader: cookieHeader,
                    userAgent: userAgent,
                    timeout: timeout
                ) else {
                    throw ParserError.manifestRequestFailed("响应为空")
                }

                return data
            } catch {
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
        timeout: TimeInterval
    ) async throws -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
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
        userAgent: String?
    ) async throws -> Int64 {
        var lastError: Error = ParserError.manifestRequestFailed("分片下载失败")
        let attempts = 2

        for attempt in 0...attempts {
            do {
                guard let data = try await performFetch(
                    url,
                    referer: referer,
                    cookieHeader: cookieHeader,
                    userAgent: userAgent,
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

                try payload.write(to: destination, options: .atomic)
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
    private var completed = 0
    private var bytes: Int64 = 0

    func advance(bytes delta: Int64) -> (completed: Int, bytes: Int64) {
        completed += 1
        bytes += max(delta, 0)
        return (completed, bytes)
    }
}