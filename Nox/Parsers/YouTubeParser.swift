import Foundation

/// YouTube 的解析实现。
///
/// 取流逻辑取自根目录的 `youtube.js`（威软 YouTube 视频下载工具 v1.2.0）：
/// 先读页面里现成的 `ytInitialPlayerResponse`，拿不到再回退到 InnerTube
/// `youtubei/v1/player` 接口（WEB 客户端，`clientVersion` 优先取页面 `ytcfg` 里的值）。
/// 解析出 `streamingData.formats`（音视频合流）与 `adaptiveFormats`（分离流）后，
/// 直接使用其中的 `url` 直链，交给 App 的分片下载管线本地下载 —— 不再经过任何第三方服务。
///
/// 与原脚本保持一致：只处理带 `url` 的格式（`signatureCipher` 的流会被跳过），
/// 也不做音视频合成。因此分离出来的视频流没有音轨，界面上会标注「仅视频」。
@MainActor
final class YouTubeParser: VideoSiteParser {
    let identifier = "youtube"
    let displayName = "YouTube"

    /// 取不到页面 `ytcfg` 时的兜底 InnerTube 版本号，与 `youtube.js` 一致。
    private static let fallbackClientVersion = "2.20250101.00.00"

    private static let hosts = [
        "youtube.com",
        "youtube-nocookie.com",
        "youtu.be"
    ]

    func canHandle(_ url: URL) -> Bool {
        guard url.scheme == "https", Self.isYouTubeHost(url.host) else { return false }
        return Self.videoID(from: url) != nil
    }

    /// 首页 / 搜索结果 / 频道页同样是 YouTube 站内页面：
    /// 虽然不能被 `canHandle` 命中（取不到 videoId），视图层也要据此隐藏通用嗅探入口。
    func claimsHost(_ url: URL) -> Bool {
        Self.isYouTubeHost(url.host)
    }

    func parse(page: WebPageContext) async throws -> [VideoVariant] {
        guard let pageURL = page.pageURL,
              let videoID = Self.videoID(from: pageURL) else {
            throw ParserError.unsupportedURL
        }

        // 1) 与脚本一致：优先用页面现成的播放器数据（最可靠，且已带当前登录态）。
        var player = await Self.pagePlayerResponse(page)

        // 2) 页面里拿不到时，回退到 InnerTube player 接口。
        if player == nil {
            player = try await Self.fetchPlayerResponse(videoID: videoID, page: page)
        }

        guard let response = player else {
            throw ParserError.noMediaDefinitions
        }

        // 不可播放（会员、地区限制、需要登录等）时带上官方给的原因，便于用户判断。
        if let status = response["playabilityStatus"] as? [String: Any],
           let state = status["status"] as? String,
           state != "OK",
           let reason = status["reason"] as? String,
           !reason.isEmpty {
            throw ParserError.pageLoadFailed(reason)
        }

        let variants = Self.variants(from: response)

        guard !variants.isEmpty else { throw ParserError.noVideoVariants }

        LogStore.shared.info("youtube parsed \(variants.count) variant(s) for \(videoID)")
        return variants
    }

    // MARK: - 视频 ID

    private static func isYouTubeHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 从常见的 YouTube 地址里取 videoId。
    /// 支持 `watch?v=`、`/shorts/`、`/live/`、`/embed/`、`/v/` 以及 `youtu.be/`。
    static func videoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            return validVideoID(url.path.split(separator: "/").first.map(String.init))
        }

        let segments = url.path.split(separator: "/").map(String.init)

        if let index = segments.firstIndex(where: { ["shorts", "live", "embed", "v"].contains($0) }),
           segments.indices.contains(index + 1) {
            return validVideoID(segments[index + 1])
        }

        if url.path == "/watch" {
            return validVideoID(queryValue("v", in: url))
        }

        return nil
    }

    private static func validVideoID(_ value: String?) -> String? {
        guard let value, (6...20).contains(value.count) else { return nil }

        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        return value
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    // MARK: - 播放器数据

    /// 读取页面里的 `ytInitialPlayerResponse`（脚本的 Method 1）。
    private static func pagePlayerResponse(_ page: WebPageContext) async -> [String: Any]? {
        let script = "(function(){try{var p=window.ytInitialPlayerResponse;"
            + "if(!p||!p.streamingData)return null;return JSON.stringify(p);}catch(e){return null;}})()"

        guard let value = try? await page.evaluate(script),
              let text = value as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        return dictionary
    }

    /// InnerTube player 请求（脚本的 fallback）。
    private static func fetchPlayerResponse(
        videoID: String,
        page: WebPageContext
    ) async throws -> [String: Any]? {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            throw ParserError.invalidURL
        }

        let clientVersion = await pageClientVersion(page) ?? fallbackClientVersion

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/watch?v=\(videoID)", forHTTPHeaderField: "Referer")

        if let userAgent = page.userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let cookie = await page.cookieHeader(matching: page.pageURL), !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let payload: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": clientVersion,
                    "hl": Self.languageHint
                ]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw ParserError.scriptFailed(error.localizedDescription)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ParserError.manifestRequestFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParserError.manifestRequestFailed("HTTP \(http.statusCode)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ParserError.invalidManifest
        }

        return dictionary
    }

    /// 页面当前的 InnerTube 版本号；取不到返回 nil，用兜底值。
    private static func pageClientVersion(_ page: WebPageContext) async -> String? {
        let script = "(function(){try{return (window.ytcfg&&window.ytcfg.get)"
            + "?window.ytcfg.get('INNERTUBE_CLIENT_VERSION'):null;}catch(e){return null;}})()"
        guard let value = try? await page.evaluate(script),
              let version = value as? String, !version.isEmpty else {
            return nil
        }
        return version
    }

    private static var languageHint: String {
        if let code = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init),
           !code.isEmpty {
            return code
        }
        return "en"
    }

    // MARK: - 取流

    /// 一个候选项，附带排序 / 去重需要的信息。
    private struct Candidate {
        let variant: VideoVariant
        let isAudio: Bool
        let isCombined: Bool
        let height: Int
        let bitrate: Int
    }

    private static func variants(from player: [String: Any]) -> [VideoVariant] {
        guard let streaming = player["streamingData"] as? [String: Any] else { return [] }

        // 合流格式（自带音轨）单独记一份 itag，用来判断某个视频格式有没有声音。
        let combined = streaming["formats"] as? [[String: Any]] ?? []
        let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        let combinedItags = Set(combined.compactMap { $0["itag"] as? Int })

        var best: [String: Candidate] = [:]

        for format in combined + adaptive {
            guard let urlString = format["url"] as? String,
                  let url = URL(string: urlString),
                  let mime = format["mimeType"] as? String else {
                // 与脚本一致：没有直链（例如只有 signatureCipher）的格式直接跳过。
                continue
            }

            let isAudio = mime.hasPrefix("audio/")
            guard isAudio || mime.hasPrefix("video/") else { continue }

            let container = Self.container(from: mime)
            let ext = container.isEmpty ? (isAudio ? "m4a" : "mp4") : container
            let rate = (format["bitrate"] as? Int) ?? 0

            let candidate: Candidate
            if isAudio {
                let kbps = max(1, rate / 1000)
                candidate = Candidate(
                    variant: VideoVariant(quality: "\(L("音频")) \(kbps)KBPS", format: ext, url: url),
                    isAudio: true,
                    isCombined: false,
                    height: 0,
                    bitrate: rate
                )
            } else {
                let label = Self.videoQualityLabel(from: format)
                let isCombined = (format["itag"] as? Int).map { combinedItags.contains($0) } ?? false
                let quality = isCombined ? label : label + " · " + L("仅视频")
                candidate = Candidate(
                    variant: VideoVariant(quality: quality, format: ext, url: url),
                    isAudio: false,
                    isCombined: isCombined,
                    height: (format["height"] as? Int) ?? 0,
                    bitrate: rate
                )
            }

            // 同类型、同清晰度、同容器只保留一条，取码率最高的。
            let key = (candidate.isAudio ? "a|" : "v|") + candidate.variant.quality + "|" + ext
            if let existing = best[key], existing.bitrate >= candidate.bitrate {
                continue
            }
            best[key] = candidate
        }

        let ordered = best.values.sorted { lhs, rhs in
            // 视频在前、音频在后
            if lhs.isAudio != rhs.isAudio { return !lhs.isAudio }
            if lhs.isAudio { return lhs.bitrate > rhs.bitrate }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            // 同分辨率下，自带音轨的合流格式排在分离格式前面
            if lhs.isCombined != rhs.isCombined { return lhs.isCombined }
            return lhs.bitrate > rhs.bitrate
        }

        return ordered.map(\.variant)
    }

    private static func videoQualityLabel(from format: [String: Any]) -> String {
        if let label = format["qualityLabel"] as? String, !label.isEmpty {
            return label.uppercased()
        }

        if let height = format["height"] as? Int, height > 0 {
            return "\(height)P"
        }

        if let quality = format["quality"] as? String, !quality.isEmpty {
            return quality.uppercased()
        }

        return L("未知清晰度")
    }

    /// 从 mimeType 里取容器名（`video/mp4; codecs=...` → `mp4`）。
    private static func container(from mime: String) -> String {
        if mime.contains("mp4") { return "mp4" }
        if mime.contains("webm") { return "webm" }
        return ""
    }
}
