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
/// 与原脚本的差别：原脚本只挑带 `url` 的格式；这里在拿不到直链时，
/// 会尝试用播放器脚本（base.js）把 `signatureCipher` 解密成直链，仍失败才跳过。
/// 也不做音视频合成，因此分离出来的视频流没有音轨，界面上会标注「仅视频」。
@MainActor
final class YouTubeParser: VideoSiteParser {
    let identifier = "youtube"
    let displayName = "YouTube"

    /// 取不到页面 `ytcfg` 时的兜底 InnerTube 版本号，与 `youtube.js` 一致。
    private static let fallbackClientVersion = "2.20250101.00.00"

    /// 取不到页面 API Key 时的兜底：YouTube 网页端固定的 InnerTube Key。
    private static let fallbackAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

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
        // 某个来源拿到了播放数据，但里面的格式全是签名加密的（没有可直接下载的直链）。
        var sawEncryptedStream = false
        // base.js 解密只做一次（在页面里是同一个播放器脚本）。
        var triedDecipher = false

        for source in PlayerSource.allCases {
            guard let response = await Self.playerResponse(from: source, videoID: videoID, page: page) else {
                LogStore.shared.info("youtube source \(source): no data")
                continue
            }

            // 被风控 / 需要登录 / 不可播放：换下一个来源再试。
            if let reason = Self.blockingReason(response) {
                blockedReason = blockedReason ?? reason
                LogStore.shared.warning("youtube source \(source) blocked: \(reason)")
                continue
            }

            // 有播放数据、却没有一条可直接下载的直链：格式都被签名加密了。
            // 先在页面里用播放器的 base.js 解密试试，成功就不用再换来源。
            if Self.hasStreamingData(response), !Self.hasDirectURL(response) {
                if !triedDecipher {
                    triedDecipher = true
                    if let upgraded = await Self.responseAddingDecipheredURLs(response, page: page) {
                        let variants = Self.variants(from: upgraded)
                        if !variants.isEmpty {
                            LogStore.shared.info("youtube deciphered \(variants.count) variant(s) via \(source) for \(videoID)")
                            return variants
                        }
                    }
                }
                sawEncryptedStream = true
                LogStore.shared.warning("youtube source \(source): 只有签名加密的流")
                continue
            }

            let variants = Self.variants(from: response)
            guard !variants.isEmpty else { continue }

            LogStore.shared.info("youtube parsed \(variants.count) variant(s) via \(source) for \(videoID)")
            return variants
        }

        // 拿到了播放数据却下不了：直说「需要签名解密」，比含糊的「找不到清晰度」更有用。
        if sawEncryptedStream {
            throw ParserError.pageLoadFailed(L("页面里的视频流需要签名解密，暂时无法直接下载。"))
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
        /// App 端发起的 ANDROID VR 客户端请求（返回直链，通常无需 PO token）
        case innerTubeAndroidVR
        /// App 端发起的 TV 内嵌客户端请求
        case innerTubeTV
    }

    private static func playerResponse(
        from source: PlayerSource,
        videoID: String,
        page: WebPageContext
    ) async -> [String: Any]? {
        switch source {
        case .pagePlayer:
            return await pageJSON(page, script: pageExtractScript(getter: pagePlayerGetter))
        case .pageInitial:
            return await pageJSON(page, script: pageExtractScript(getter: pageInitialGetter))
        case .pageConfig:
            return await pageJSON(page, script: pageExtractScript(getter: pageConfigGetter))
        case .innerTubeWeb:
            return await innerTubeResponse(profile: .web, videoID: videoID, page: page)
        case .innerTubeIOS:
            return await innerTubeResponse(profile: .ios, videoID: videoID, page: page)
        case .innerTubeAndroidVR:
            return await innerTubeResponse(profile: .androidVR, videoID: videoID, page: page)
        case .innerTubeTV:
            return await innerTubeResponse(profile: .tv, videoID: videoID, page: page)
        }
    }

    /// 在页面里执行脚本，把返回的 JSON 字符串解析成字典。
    ///
    /// 不要求一定有 streamingData：视频不可播放时同样要把 playabilityStatus 带回来。
    private static func pageJSON(_ page: WebPageContext, script: String) async -> [String: Any]? {
        guard let value = try? await page.evaluate(script),
              let text = value as? String,
              let data = text.data(using: .utf8) else {
            return nil
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        return object as? [String: Any]
    }

    /// 返回 `playabilityStatus` 里的拦截原因；可播放时返回 nil。
    private static func blockingReason(_ response: [String: Any]) -> String? {
        if let status = response["playabilityStatus"] as? [String: Any] {
            let state = status["status"] as? String
            if state == "OK" { return nil }

            if let reason = status["reason"] as? String, !reason.isEmpty {
                return reason
            }

            return L("该视频当前不可播放。")
        }

        // 没有 playabilityStatus：多半是 InnerTube 返回的错误体（例如 API Key 无效）。
        // 把错误信息带回去，比笼统的「视频无法播放」有用。
        if let error = response["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }

        return nil
    }

    // MARK: - 页面内脚本

    /// 页面里正在播放的响应 getter（比首屏的 ytInitialPlayerResponse 更新）。
    private static let pagePlayerGetter =
        "(function(){var el=document.getElementById('movie_player');"
        + "return (el&&typeof el.getPlayerResponse==='function')?el.getPlayerResponse():null;})()"

    private static let pageInitialGetter = "window.ytInitialPlayerResponse"

    private static let pageConfigGetter =
        "(function(){var a=window.ytplayer&&window.ytplayer.config&&window.ytplayer.config.args;"
        + "var r=a&&a.raw_player_response;return r?JSON.parse(r):null;})()"

    /// 把播放器响应压缩成只含需要字段的 JSON 再带回 Swift。
    ///
    /// 完整响应动辄一两 MB（还带字幕、videoDetails 等），整份 stringify 既慢又容易在
    /// 桥接时出错；这里只挑 formats / adaptiveFormats 的直链相关字段，同时保留
    /// playabilityStatus —— 视频不可播放时也能把页面的真实原因带回来看。
    private static func pageExtractScript(getter: String) -> String {
        return "(function(){try{var p=" + getter + ";if(!p)return null;"
            + "var pick=function(f){return {itag:f.itag,url:f.url||null,"
            + "signatureCipher:f.signatureCipher||f.cipher||null,mimeType:f.mimeType,"
            + "bitrate:f.bitrate,height:f.height,qualityLabel:f.qualityLabel,quality:f.quality};};"
            + "var sd=p.streamingData;"
            + "var out={playabilityStatus:p.playabilityStatus,streamingData:null};"
            + "if(sd){out.streamingData={formats:(sd.formats||[]).map(pick),"
            + "adaptiveFormats:(sd.adaptiveFormats||[]).map(pick)};}"
            + "return JSON.stringify(out);}catch(e){return null;}})()"
    }

    private static let clientVersionScript =
        "(function(){try{return (window.ytcfg&&window.ytcfg.get)"
        + "?String(window.ytcfg.get('INNERTUBE_CLIENT_VERSION')||''):'';}catch(e){return '';}})()"

    private static let userAgentScript =
        "(function(){try{return navigator.userAgent||'';}catch(e){return '';}})()"

    private static let visitorDataScript =
        "(function(){try{return (window.ytcfg&&window.ytcfg.get)"
        + "?String(window.ytcfg.get('VISITOR_DATA')||''):'';}catch(e){return '';}})()"

    /// 页面 ytcfg 里的 InnerTube API Key（youtubei/v1/player 的 key= 参数）。
    private static let apiKeyScript =
        "(function(){try{return (window.ytcfg&&window.ytcfg.get)"
        + "?String(window.ytcfg.get('INNERTUBE_API_KEY')||''):'';}catch(e){return '';}})()"

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

        /// Android VR 客户端：返回直链、且通常不要求 PO token，是最稳的一条。
        static let androidVR = ClientProfile(
            name: "ANDROID_VR",
            version: "1.60.19",
            numericID: "28",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; GB) gzip",
            androidSdkVersion: 32,
            deviceModel: "Quest 3",
            osName: "Android",
            osVersion: "12"
        )

        /// 电视内嵌客户端：同样常返回直链。
        static let tv = ClientProfile(
            name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            version: "2.0",
            numericID: "85",
            userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/16.0 Safari/605.1.15",
            androidSdkVersion: nil,
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

        // 关键：youtubei/v1/player 必须带 key=，否则 YouTube 直接返回 400。
        // 少了它，App 端的 iOS / ANDROID VR / TV 来源全都拿不到数据，
        // 只能退回页面里那份带 signatureCipher 的响应，于是报「需要签名解密」。
        let apiKey = await pageString(page, script: apiKeyScript, fallback: fallbackAPIKey)

        guard let endpoint = URL(string:
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&key=" + apiKey) else {
            return nil
        }

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
        request.setValue("https://www.youtube.com/watch?v=" + videoID, forHTTPHeaderField: "Referer")
        request.setValue(profile.numericID, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        // 只有 WEB 客户端用浏览器 Cookie 认证：官方客户端走各自的凭证，混用反而可能被拒。
        if isWeb, let cookie = await page.cookieHeader(matching: page.pageURL), !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")

            // 关键：带上 SAPISIDHASH。YouTube 的网页端 API 靠它确认请求来自已登录的网页；
            // 只带 Cookie 不带这个头，会被当成未登录，弹「请登录，以便我们确认你不是聊天机器人」。
            if let authorization = Self.sapisidAuthorization(cookieHeader: cookie) {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
                request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
                request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            }
        }

        var context: [String: Any] = ["client": client]
        if profile.name.hasPrefix("TVHTML5") {
            context["thirdParty"] = ["embedUrl": "https://www.youtube.com/"]
        }

        let payload: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": context
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            LogStore.shared.warning("youtube innertube " + profile.name + ": 请求失败")
            return nil
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            LogStore.shared.warning("youtube innertube " + profile.name + ": HTTP " + String(http.statusCode))
            return nil
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
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

    /// 响应里是否有 streamingData（有就说明视频本身可播放）。
    private static func hasStreamingData(_ response: [String: Any]) -> Bool {
        // 注意 JSON 的 null 会变成 NSNull：必须判断真的是字典，否则 null 会被当成「有数据」。
        response["streamingData"] is [String: Any]
    }

    /// streamingData 里是否至少有一条能直接用（带 url，或 signatureCipher 不含 s）。
    private static func hasDirectURL(_ response: [String: Any]) -> Bool {
        guard let streaming = response["streamingData"] as? [String: Any] else { return false }

        let all = (streaming["formats"] as? [[String: Any]] ?? [])
            + (streaming["adaptiveFormats"] as? [[String: Any]] ?? [])

        return all.contains { ($0["mimeType"] as? String) != nil && mediaURL(from: $0) != nil }
    }

    /// 取格式的直链。
    ///
    /// - 优先用 url；
    /// - signatureCipher / cipher 只有在**不含 s 参数**时才等价于直链，可以直接用；
    /// - 带 s 的签名需要用播放器脚本解密，本实现没有引入那段逻辑，返回 nil 跳过。
    private static func mediaURL(from format: [String: Any]) -> URL? {
        if let value = format["url"] as? String, !value.isEmpty, let url = URL(string: value) {
            return url
        }

        guard let cipher = (format["signatureCipher"] as? String) ?? (format["cipher"] as? String),
              !cipher.isEmpty,
              let components = URLComponents(string: "?" + cipher) else {
            return nil
        }

        let items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "s" }),
              let raw = items.first(where: { $0.name == "url" })?.value,
              let url = URL(string: raw) else {
            return nil
        }

        return url
    }

    /// 在页面里执行：用播放器脚本（base.js）把 signatureCipher 解密成直链。
    ///
    /// 解密函数必须从 base.js 里按结构抽出来（签名函数 + 它调用的辅助对象），
    /// 用 JS 的正则和花括号配对来做，比在 Swift 里容易得多；而且这段跑在页面里
    /// 可以直接命中浏览器已缓存的 base.js。
    private static let decipherScript = #"""
var debug = [];
var out = [];

function isIdentChar(ch) {
  return /[A-Za-z0-9_$]/.test(ch);
}

function braceBlock(src, start) {
  var depth = 0;
  for (var i = start; i < src.length && i < start + 300000; i++) {
    var ch = src.charAt(i);
    if (ch === "{") { depth++; }
    else if (ch === "}") {
      depth--;
      if (depth === 0) { return src.substring(start, i + 1); }
    }
  }
  return null;
}

function objectTexts(src, name) {
  var found = [];
  var from = 0;
  while (found.length < 60) {
    var idx = src.indexOf(name, from);
    if (idx < 0) { break; }
    from = idx + 1;
    if (idx > 0 && isIdentChar(src.charAt(idx - 1))) { continue; }
    var j = idx + name.length;
    while (j < src.length && /\s/.test(src.charAt(j))) { j++; }
    if (src.charAt(j) !== "=") { continue; }
    j++;
    while (j < src.length && /\s/.test(src.charAt(j))) { j++; }
    if (src.charAt(j) !== "{") { continue; }
    var text = braceBlock(src, j);
    if (text) { found.push(text); }
  }
  return found;
}

function hasMethods(text, names) {
  for (var i = 0; i < names.length; i++) {
    var esc = names[i].replace(/[^A-Za-z0-9_]/g, "\\$&");
    var re = new RegExp("(?:^|[,{\\s])" + esc + "\\s*[:(]");
    if (!re.test(text)) { return false; }
  }
  return true;
}

function candidateFunctions(src) {
  var list = [];
  var patterns = [
    /(?:^|[^A-Za-z0-9_$])([A-Za-z0-9_$]{1,6})\s*=\s*function\s*\(\s*([A-Za-z0-9_$]+)\s*\)\s*\{([\s\S]{0,8000}?)return\s+\2\.join\(\s*""\s*\)/g,
    /function\s+([A-Za-z0-9_$]{1,6})\s*\(\s*([A-Za-z0-9_$]+)\s*\)\s*\{([\s\S]{0,8000}?)return\s+\2\.join\(\s*""\s*\)/g
  ];
  for (var p = 0; p < patterns.length && list.length < 40; p++) {
    var re = patterns[p];
    var m;
    while ((m = re.exec(src)) !== null) {
      list.push({ name: m[1], arg: m[2], body: m[3] });
      if (list.length >= 40) { break; }
    }
  }
  return list;
}

function buildFromCandidate(cand, src) {
  var callRe = /([A-Za-z0-9_$]+)\s*\.\s*([A-Za-z0-9_$]+)\s*\(\s*[A-Za-z0-9_$]+\s*(?:,\s*(\d+)\s*)?\)/g;
  var calls = [];
  var objName = null;
  var c;
  while ((c = callRe.exec(cand.body)) !== null) {
    if (objName === null) { objName = c[1]; }
    else if (objName !== c[1]) { continue; }
    calls.push([c[2], c[3] ? parseInt(c[3], 10) : 0]);
  }
  if (!objName || !calls.length) { return null; }

  var names = [];
  for (var i = 0; i < calls.length; i++) {
    if (names.indexOf(calls[i][0]) < 0) { names.push(calls[i][0]); }
  }

  var candidates = objectTexts(src, objName);
  for (var k = 0; k < candidates.length; k++) {
    if (!hasMethods(candidates[k], names)) { continue; }
    try {
      var obj = eval("(" + candidates[k] + ")");
      if (obj) { return { obj: obj, calls: calls }; }
    } catch (e) {}
  }
  return null;
}

function decipherOne(cipher, dec) {
  var params;
  try { params = new URLSearchParams(cipher); } catch (e) { return null; }
  var sig = params.get("s");
  var url = params.get("url");
  var sp = params.get("sp") || "signature";
  if (!url) { return null; }
  if (!sig) { return url; }
  var chars = sig.split("");
  for (var i = 0; i < dec.calls.length; i++) {
    var fn = dec.obj[dec.calls[i][0]];
    if (typeof fn === "function") { fn(chars, dec.calls[i][1]); }
  }
  return url + "&" + sp + "=" + encodeURIComponent(chars.join(""));
}

if (!ciphers || !ciphers.length) { return { urls: [], debug: "no ciphers" }; }

var jsUrl = null;
try {
  if (window.ytcfg && typeof window.ytcfg.get === "function") {
    jsUrl = window.ytcfg.get("PLAYER_JS_URL");
  }
  if (!jsUrl && window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.assets) {
    jsUrl = window.ytInitialPlayerResponse.assets.js;
  }
} catch (e) { jsUrl = null; }
if (!jsUrl) { return { urls: [], debug: "player js url not found" }; }

var srcText = null;
try {
  srcText = await fetch(new URL(jsUrl, location.origin).href).then(function (r) { return r.text(); });
} catch (e) { srcText = null; }
if (!srcText) { return { urls: [], debug: "player js fetch failed" }; }

var cands = candidateFunctions(srcText);
debug.push("signature candidates=" + cands.length);
var dec = null;
for (var ci = 0; ci < cands.length; ci++) {
  dec = buildFromCandidate(cands[ci], srcText);
  if (dec) { debug.push("using " + cands[ci].name); break; }
}
if (!dec) { return { urls: out, debug: debug.join(" | ") }; }

for (var k = 0; k < ciphers.length; k++) {
  out.push(decipherOne(ciphers[k], dec));
}
return { urls: out, debug: debug.join(" | ") };
"""#
    /// 把响应里带 signatureCipher 的格式在页面里解密成直链，返回补好 url 的新响应。
    ///
    /// 解密在页面里完成（见 decipherScript）；这段是收集 cipher、调用、再写回结果。
    private static func responseAddingDecipheredURLs(
        _ response: [String: Any],
        page: WebPageContext
    ) async -> [String: Any]? {
        guard let streaming = response["streamingData"] as? [String: Any] else { return nil }

        var groups: [[[String: Any]]] = [
            streaming["formats"] as? [[String: Any]] ?? [],
            streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        ]

        // 收集需要解密的 cipher，并记住它在哪个数组的哪一项。
        var ciphers: [String] = []
        var slots: [(group: Int, index: Int)] = []

        for group in groups.indices {
            for index in groups[group].indices {
                guard let cipher = cipherString(from: groups[group][index]) else { continue }
                ciphers.append(cipher)
                slots.append((group, index))
            }
        }

        guard !ciphers.isEmpty else { return nil }

        guard let raw = try? await page.evaluateAsync(decipherScript, arguments: ["ciphers": ciphers]),
              let result = raw as? [String: Any],
              let results = result["urls"] as? [Any] else {
            return nil
        }

        if let debug = result["debug"] as? String, !debug.isEmpty {
            LogStore.shared.info("youtube decipher: " + debug)
        }

        guard results.count == ciphers.count else { return nil }

        var resolved = 0
        for (offset, slot) in slots.enumerated() {
            guard let value = results[offset] as? String, !value.isEmpty else { continue }
            groups[slot.group][slot.index]["url"] = value
            resolved += 1
        }

        guard resolved > 0 else { return nil }

        var newStreaming = streaming
        newStreaming["formats"] = groups[0]
        newStreaming["adaptiveFormats"] = groups[1]

        var newResponse = response
        newResponse["streamingData"] = newStreaming
        return newResponse
    }

    /// 取格式里**需要解密**的签名串；不需要解密时返回 nil。
    ///
    /// JSON 的 null 会变成 NSNull，所以不能直接判断 format["url"] == nil：
    /// 页面来源的响应里 url 恒为 null，那种写法会让解密永远收不到 cipher
    /// （解密分支被跳过，最后只报「需要签名解密」）。
    private static func cipherString(from format: [String: Any]) -> String? {
        if let url = format["url"] as? String, !url.isEmpty { return nil }

        guard let cipher = (format["signatureCipher"] as? String) ?? (format["cipher"] as? String),
              !cipher.isEmpty else {
            return nil
        }

        return cipher
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
            guard let mime = format["mimeType"] as? String,
                  let url = mediaURL(from: format) else {
                // 与脚本一致：拿不到直链（例如只有带 s 的 signatureCipher）的格式跳过。
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
