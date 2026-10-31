import CryptoKit
import Foundation
import NoxCore


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
/// 取流顺序（对齐根目录新脚本 ytx-direct-downloader 的做法）：
/// 1. 优先读页面/InnerTube 里的现成直链；格式带 `signatureCipher` 时用播放器
///    base.js 在页面里解密。
/// 2. 都拿不到就退回**页面自己播放时抓到的已签名 googlevideo 直链**
///    （见 VideoParser.youtubeMediaUserScript）—— 独立客户端被风控时这条最稳。
/// 3. 仍然为空就提示用户先播放 2～3 秒再重新解析。
/// 不做音视频合成，因此分离出来的视频流没有音轨，界面上会标注「仅视频」。
@MainActor
final class YouTubeParser: VideoSiteParser {
    let identifier = "youtube"
    let displayName = "YouTube"

    /// 取不到页面 `ytcfg` 时的兜底 InnerTube 版本号，与 `youtube.js` 一致。
    static let fallbackClientVersion = "2.20250101.00.00"

    /// 取不到页面 API Key 时的兜底：YouTube 网页端固定的 InnerTube Key。
    static let fallbackAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    /// YouTube 网页端 API 的 Origin，SAPISIDHASH 也要按它计算。
    static let origin = "https://www.youtube.com"

    /// 页面 UA 取不到时的兜底：普通桌面 Chrome，避免用 CFNetwork 的默认 UA 去请求。
    static let fallbackUserAgent =
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
        var fromSources: [VideoVariant] = []

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
                            fromSources = variants
                            break
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
            fromSources = variants
            break
        }

        // 页面播放时抓到的已签名直链：不用解密、也不用 PO token，是最稳的一条。
        let captured = await Self.capturedVariants(page: page)

        let merged = Self.merged(fromSources, captured)
        if !merged.isEmpty {
            LogStore.shared.info("youtube \(videoID): source=\(fromSources.count) captured=\(captured.count)")
            return merged
        }

        // 两条路都没结果。原脚本在这种情况下的提示也是「先播放几秒再重试」，
        // 这里给出同样可操作的指引，而不是一句无从下手的「需要签名解密」。
        if sawEncryptedStream || blockedReason != nil {
            throw ParserError.pageLoadFailed(L("没能拿到可下载的直链。请先让当前网页播放 2～3 秒，再点「重新解析」。"))
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
}
