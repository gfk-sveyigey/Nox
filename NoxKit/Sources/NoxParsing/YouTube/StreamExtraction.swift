import CryptoKit
import Foundation
import NoxCore

extension YouTubeParser {
    // MARK: - 抓取页面播放时的直链

    /// 读取页面上抓到的 googlevideo 直链，转成清晰度列表。
    ///
    /// 见 VideoParser.youtubeMediaUserScript()：YouTube 播放时自己会去请求
    /// 已经签好名的 videoplayback 地址，把它们记下来就等于拿到了可直接下载的
    /// 直链 —— 既不需要签名解密，也不需要 PO token。根目录新脚本
    /// （ytx-direct-downloader）在独立客户端被风控时，靠的正是这条路。
    static func capturedVariants(page: WebPageContext) async -> [VideoVariant] {
        guard let raw = try? await page.evaluate(capturedMediaScript),
              let items = raw as? [[String: Any]], !items.isEmpty else {
            return []
        }

        var seenURLs = Set<String>()
        var variants: [VideoVariant] = []

        for item in items {
            guard let urlString = item["url"] as? String,
                  let url = URL(string: urlString),
                  seenURLs.insert(urlString).inserted else { continue }

            let itag = (item["itag"] as? Int) ?? 0
            let mime = ((item["mime"] as? String) ?? "").lowercased()
            let fallback = itagFallbacks[itag]

            let isAudio = mime.hasPrefix("audio/") || (mime.isEmpty && fallback?.kind == "audio")
            let isMuxed = fallback?.kind == "muxed"

            let mimeContainer = Self.container(from: mime)
            let container = mimeContainer.isEmpty
                ? (fallback?.container ?? (isAudio ? "m4a" : "mp4"))
                : mimeContainer

            let quality: String
            if isAudio {
                quality = L("音频")
            } else {
                let height = fallback?.height ?? 0
                let fps = fallback?.fps ?? 0
                var label = height > 0 ? "\(height)p" : L("视频")
                if fps > 30 { label += "\(fps)" }
                if !isMuxed { label += " · " + L("仅视频") }
                quality = label
            }

            variants.append(VideoVariant(quality: quality, format: container, url: url))
        }

        return variants
    }

    /// 合并两条来源的结果，按地址去重；来源解析出来的排在前面。
    static func merged(_ primary: [VideoVariant], _ extra: [VideoVariant]) -> [VideoVariant] {
        var seen = Set(primary.map { $0.url.absoluteString })
        var result = primary

        for variant in extra where seen.insert(variant.url.absoluteString).inserted {
            result.append(variant)
        }

        return result
    }

    /// 页面里抓到的直链只有 itag、没有分辨率信息时用它兜底（与脚本里的表一致）。
    struct ItagFallback {
        let kind: String
        let container: String
        let height: Int
        let fps: Int
    }

    static let itagFallbacks: [Int: ItagFallback] = [
        18: ItagFallback(kind: "muxed", container: "mp4", height: 360, fps: 30),
        22: ItagFallback(kind: "muxed", container: "mp4", height: 720, fps: 30),
        133: ItagFallback(kind: "video", container: "mp4", height: 240, fps: 30),
        134: ItagFallback(kind: "video", container: "mp4", height: 360, fps: 30),
        135: ItagFallback(kind: "video", container: "mp4", height: 480, fps: 30),
        136: ItagFallback(kind: "video", container: "mp4", height: 720, fps: 30),
        137: ItagFallback(kind: "video", container: "mp4", height: 1080, fps: 30),
        138: ItagFallback(kind: "video", container: "mp4", height: 2160, fps: 30),
        160: ItagFallback(kind: "video", container: "mp4", height: 144, fps: 30),
        264: ItagFallback(kind: "video", container: "mp4", height: 1440, fps: 30),
        266: ItagFallback(kind: "video", container: "mp4", height: 2160, fps: 30),
        298: ItagFallback(kind: "video", container: "mp4", height: 720, fps: 60),
        299: ItagFallback(kind: "video", container: "mp4", height: 1080, fps: 60),
        399: ItagFallback(kind: "video", container: "mp4", height: 1080, fps: 30),
        400: ItagFallback(kind: "video", container: "mp4", height: 1440, fps: 30),
        401: ItagFallback(kind: "video", container: "mp4", height: 2160, fps: 30),
        139: ItagFallback(kind: "audio", container: "m4a", height: 0, fps: 0),
        140: ItagFallback(kind: "audio", container: "m4a", height: 0, fps: 0),
        141: ItagFallback(kind: "audio", container: "m4a", height: 0, fps: 0),
        242: ItagFallback(kind: "video", container: "webm", height: 240, fps: 30),
        243: ItagFallback(kind: "video", container: "webm", height: 360, fps: 30),
        244: ItagFallback(kind: "video", container: "webm", height: 480, fps: 30),
        247: ItagFallback(kind: "video", container: "webm", height: 720, fps: 30),
        248: ItagFallback(kind: "video", container: "webm", height: 1080, fps: 30),
        271: ItagFallback(kind: "video", container: "webm", height: 1440, fps: 30),
        272: ItagFallback(kind: "video", container: "webm", height: 2160, fps: 30),
        278: ItagFallback(kind: "video", container: "webm", height: 144, fps: 30),
        302: ItagFallback(kind: "video", container: "webm", height: 720, fps: 60),
        303: ItagFallback(kind: "video", container: "webm", height: 1080, fps: 60),
        308: ItagFallback(kind: "video", container: "webm", height: 1440, fps: 60),
        313: ItagFallback(kind: "video", container: "webm", height: 2160, fps: 30),
        315: ItagFallback(kind: "video", container: "webm", height: 2160, fps: 60),
        330: ItagFallback(kind: "video", container: "webm", height: 144, fps: 60),
        331: ItagFallback(kind: "video", container: "webm", height: 240, fps: 60),
        332: ItagFallback(kind: "video", container: "webm", height: 360, fps: 60),
        333: ItagFallback(kind: "video", container: "webm", height: 480, fps: 60),
        334: ItagFallback(kind: "video", container: "webm", height: 720, fps: 60),
        335: ItagFallback(kind: "video", container: "webm", height: 1080, fps: 60),
        336: ItagFallback(kind: "video", container: "webm", height: 1440, fps: 60),
        337: ItagFallback(kind: "video", container: "webm", height: 2160, fps: 60),
        249: ItagFallback(kind: "audio", container: "webm", height: 0, fps: 0),
        250: ItagFallback(kind: "audio", container: "webm", height: 0, fps: 0),
        251: ItagFallback(kind: "audio", container: "webm", height: 0, fps: 0)
    ]

    /// 页面里读取抓取结果的脚本（见 VideoParser.youtubeMediaUserScript()）。
    static let capturedMediaScript =
        "(function(){try{return (window.__noxYTMediaRead?window.__noxYTMediaRead():[])}catch(e){return []}})()"

    // MARK: - 取流

    /// 一个候选项，附带排序 / 去重需要的信息。
    struct Candidate {
        let variant: VideoVariant
        let isAudio: Bool
        let isCombined: Bool
        let height: Int
        let bitrate: Int
    }

    static func variants(from player: [String: Any]) -> [VideoVariant] {
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

    static func videoQualityLabel(from format: [String: Any]) -> String {
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
    static func container(from mime: String) -> String {
        if mime.contains("mp4") { return "mp4" }
        if mime.contains("webm") { return "webm" }
        return ""
    }
}
