import CryptoKit
import Foundation

/// YouTube 的解析实现。
///
/// 取流逻辑取自根目录的 `youtube.js`（威软 YouTube 视频下载工具 v1.2.0）：
/// 优先读页面里现成的播放器数据，拿不到再回退到 InnerTube `youtubei/v1/player` 接口，
/// 然后用 `streamingData` 里的 `url` 直链交给 App 的分片下载管线本地下载。
///
/// 与原脚本的差别只在「怎么拿数据」：YouTube 会按客户端指纹 / 会话判定机器人，
/// 返回 `LOGIN_REQUIRED`（「请登录，以便我们确认你不是聊天机器人」）。
/// 原脚本跑在浏览器里、且只走 WEB 一条路；这里改成**依次尝试多个来源**，
/// 页面数据被拦就换 App 端的 iOS / ANDROID 客户端，任何一条成功即可，
/// 不再让单一来源的拦截拖垮整次解析。
///
/// 与原脚本一致：只处理带 `url` 的格式（`signatureCipher` 的流会被跳过），
/// 也不做音视频合成。因此分离出来的视频流没有音轨，界面上会标注「仅视频」。
@MainActor
final class YouTubeParser: VideoSiteParser {
    let identifier = "youtube"
    let displayName = "YouTube"

    /// 取不到页面 `ytcfg` 时的兜底 InnerTube 版本号，与 `youtube.js` 一致。
    private static let fallbackClientVersion = "2.20250101.00.00"

    /// YouTube 网页端 API 的 Origin，SAPISIDHASH 也要按它计算。
    private static let origin = "https://www.youtube.com"

    /// 页面 UA 取不到时的兜底：普通桌面 Chrome，避免用 CFNetwork 的默认 UA 去请求。
    private static let fallbackUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

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

        var blockedReason: String?

        for source in PlayerSource.allCases {
            guard let response = await Self.playerResponse(from: source, videoID: videoID, page: page) else {
                continue
            }

            // 被风控 / 需要登录：换下一个来源再试。
            if let reason = Self.blockingReason(response) {
                blockedReason = blockedReason ?? reason
                LogStore.shared.warning("youtube source \(source) blocked: \(reason)")
                continue
            }

            let variants = Self.variants(from: response)
            guard !variants.isEmpty else { continue }

            LogStore.shared.info("youtube parsed \(variants.count) variant(s) via \(source) for \(videoID)")
            return variants
        }

        // 所有来源都被拦：把官方给的原因抛出去，便于用户判断。
        if let blockedReason {
            throw ParserError.pageLoadFailed(blockedReason)
        }

        throw ParserError.noVideoVariants
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

    /// 取播放器数据的来源，按「成功率从高到低」依次尝试。
    private enum PlayerSource: CaseIterable {
        /// 页面里**正在播放**的响应：最新，且已通过 YouTube 自己的校验
        case pagePlayer
        /// 页面首屏写入的 `ytInitialPlayerResponse`
        case pageInitial
        /// 页面 `ytplayer.config.args.raw_player_response`
        case pageConfig
        /// App 端发起的 WEB 客户端 InnerTube 请求（沿用页面的 UA / 版本号 / Cookie）
        case innerTubeWeb
        /// App 端发起的 iOS 客户端 InnerTube 请求（通常不要求 PO token）
        case innerTubeIOS
        /// App 端发起的 ANDROID 客户端 InnerTube 请求
        case innerTubeAndroid
    }

    private static func playerResponse(
        from source: PlayerSource,
        videoID: String,
        page: WebPageContext
    ) async -> [String: Any]? {
        switch source {
        case .pagePlayer:
            return await pageJSON(page, script: pagePlayerScript)
        case .pageInitial:
            return await pageJSON(page, script: pageInitialScript)
        case .pageConfig:
            return await pageJSON(page, script: pageConfigScript)
        case .innerTubeWeb:
            return await innerTubeResponse(profile: .web, videoID: videoID, page: page)
        case .innerTubeIOS:
            return await innerTubeResponse(profile: .ios, videoID: videoID, page: page)
        case .innerTubeAndroid:
            return await innerTubeResponse(profile: .android, videoID: videoID, page: page)
        }
    }

    /// 在页面里执行脚本，把返回的 JSON 字符串解析成含 `streamingData` 的字典。
    private static func pageJSON(_ page: WebPageContext, script: String) async -> [String: Any]? {
        guard let value = try? await page.evaluate(script),
              let text = value as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary["streamingData"] != nil else {
            return nil
        }

        return dictionary
    }

    /// 返回 `playabilityStatus` 里的拦截原因；可播放时返回 nil。
    private static func blockingReason(_ response: [String: Any]) -> String? {
        guard let status = response["playabilityStatus"] as? [String: Any],
              let state = status["status"] as? String,
              state != "OK" else {
            return nil
        }

        if let reason = status["reason"] as? String, !reason.isEmpty {
            return reason
        }

        return L("该视频当前不可播放。")
    }

    // MARK: - 页面内脚本

    /// 页面里正在播放的响应，比首屏的 `ytInitialPlayerResponse` 更新。
    private static let pagePlayerScript =
        "(function(){try{var el=document.getElementById('movie_player');"
        + "if(!el||typeof el.getPlayerResponse!=='function')return null;"
        + "var r=el.getPlayerResponse();if(!r||!r.streamingData)return null;"
        + "return JSON.stringify(r);}catch(e){return null;}})()"

    private static let pageInitialScript =
        "(function(){try{var p=window.ytInitialPlayerResponse;"
        + "if(!p||!p.streamingData)return null;return JSON.stringify(p);}catch(e){return null;}})()"

    private static let pageConfigScript =
        "(function(){try{var a=window.ytplayer&&window.ytplayer.config&&window.ytplayer.config.args;"
        + "var raw=a&&a.raw_player_response;if(!raw)return null;"
        + "var r=JSON.parse(raw);if(!r||!r.streamingData)return null;"
        + "return JSON.stringify(r);}catch(e){return null;}})()"

    private static let clientVersionScript =
        "(function(){try{return (window.ytcfg&&window.ytcfg.get)"
        + "?String(window.ytcfg.get('INNERTUBE_CLIENT_VERSION')||''):'';}catch(e){return '';}})()"

    private static let userAgentScript =
        "(function(){try{return navigator.userAgent||'';}catch(e){return '';}})()"

    private static let visitorDataScript =
        "(function(){try{return (window.ytcfg&&window.ytcfg.get)"
        + "?String(window.ytcfg.get('VISITOR_DATA')||''):'';}catch(e){return '';}})()"

    private static func pageString(_ page: WebPageContext, script: String, fallback: String) async -> String {
        guard let value = try? await page.evaluate(script),
              let text = value as? String, !text.isEmpty else {
            return fallback
        }
        return text
    }

    private static var languageHint: String {
        if let code = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init),
           !code.isEmpty {
            return code
        }
        return "en"
    }

    // MARK: - InnerTube 客户端

    /// 一个 InnerTube 客户端指纹。
    private struct ClientProfile {
        let name: String
        let version: String
        /// `X-Youtube-Client-Name` 头用的数字 ID
        let numericID: String
        let userAgent: String
        let androidSdkVersion: Int?
        let deviceModel: String?
        let osName: String?
        let osVersion: String?

        /// WEB 客户端：版本号 / UA 都取页面里的值。
        static let web = ClientProfile(
            name: "WEB",
            version: "",
            numericID: "1",
            userAgent: "",
            androidSdkVersion: nil,
            deviceModel: nil,
            osName: nil,
            osVersion: nil
        )

        /// iOS 客户端：返回可直接下载的直链，且通常不要求 PO token。
        static let ios = ClientProfile(
            name: "IOS",
            version: "19.29.1",
            numericID: "5",
            userAgent: "com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)",
            androidSdkVersion: nil,
            deviceModel: "iPhone16,2",
            osName: "iPhone",
            osVersion: "18.1.0.22B83"
        )

        /// Android 客户端：同上，作为最后一条退路。
        static let android = ClientProfile(
            name: "ANDROID",
            version: "19.35.36",
            numericID: "3",
            userAgent: "com.google.android.youtube/19.35.36 (Linux; U; Android 14) gzip",
            androidSdkVersion: 34,
            deviceModel: nil,
            osName: nil,
            osVersion: nil
        )
    }

    /// 从 App 端发起一次 InnerTube player 请求；任何失败都返回 nil，交给下一个来源。
    private static func innerTubeResponse(
        profile: ClientProfile,
        videoID: String,
        page: WebPageContext
    ) async -> [String: Any]? {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            return nil
        }

        let isWeb = profile.name == "WEB"

        // WEB 沿用页面里的版本号与 UA；官方客户端用各自固定的指纹。
        let version = isWeb
            ? await pageString(page, script: clientVersionScript, fallback: fallbackClientVersion)
            : profile.version

        let userAgent = isWeb
            ? await pageString(page, script: userAgentScript, fallback: fallbackUserAgent)
            : profile.userAgent

        // 带上页面的 visitorData / 登录 Cookie，请求才像同一个会话。
        let visitorData = await pageString(page, script: visitorDataScript, fallback: "")

        var client: [String: Any] = [
            "clientName": profile.name,
            "clientVersion": version,
            "hl": Self.languageHint
        ]
        if !isWeb {
            client["userAgent"] = profile.userAgent
            if let model = profile.deviceModel { client["deviceModel"] = model }
            if let osName = profile.osName { client["osName"] = osName }
            if let osVersion = profile.osVersion { client["osVersion"] = osVersion }
            if let sdk = profile.androidSdkVersion { client["androidSdkVersion"] = sdk }
        }
        if !visitorData.isEmpty { client["visitorData"] = visitorData }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/watch?v=\(videoID)", forHTTPHeaderField: "Referer")
        request.setValue(profile.numericID, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        // 只有 WEB 客户端用浏览器 Cookie 认证：官方客户端走各自的凭证，混用反而可能被拒。
        if isWeb, let cookie = await page.cookieHeader(matching: page.pageURL), !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")

            // 关键：带上 SAPISIDHASH。YouTube 的网页端 API 靠它确认「请求来自已登录的网页」；
            // 只带 Cookie 不带这个头，会被当成未登录，弹「请登录，以便我们确认你不是聊天机器人」。
            if let authorization = Self.sapisidAuthorization(cookieHeader: cookie) {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
                request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
                request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            }
        }

        let payload: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": ["client": client]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        return dictionary
    }

    /// 由 SAPISID Cookie 生成网页端用的 `Authorization: SAPISIDHASH <时间戳>_<sha1>`。
    ///
    /// 算法：`sha1("<unix 秒> <SAPISID> https://www.youtube.com")`，时间戳与哈希用下划线连接。
    /// 优先用 `SAPISID`（对应 `SAPISIDHASH`），退而用 `__Secure-3PAPISID`（对应 `SAPISID3HASH`）；
    /// 两者都没有时返回 nil，退化为未登录请求。
    private static func sapisidAuthorization(cookieHeader: String) -> String? {
        var cookieValues: [String: String] = [:]
        for pair in cookieHeader.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            cookieValues[name] = String(parts[1])
        }

        let candidates: [(header: String, cookie: String)] = [
            ("SAPISIDHASH", "SAPISID"),
            ("SAPISID3HASH", "__Secure-3PAPISID")
        ]

        guard let match = candidates.first(where: { !(cookieValues[$0.cookie] ?? "").isEmpty }),
              let secret = cookieValues[match.cookie] else {
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let input = "\(timestamp) \(secret) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        return "\(match.header) \(timestamp)_\(hex)"
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
