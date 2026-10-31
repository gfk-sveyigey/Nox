import CryptoKit
import Foundation
import NoxCore

extension YouTubeParser {
    // MARK: - 播放器数据

    /// 取播放器数据的来源，按「成功率从高到低」依次尝试。
    enum PlayerSource: CaseIterable {
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

    static func playerResponse(
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
    static func pageJSON(_ page: WebPageContext, script: String) async -> [String: Any]? {
        guard let value = try? await page.evaluate(script),
              let text = value as? String,
              let data = text.data(using: .utf8) else {
            return nil
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        return object as? [String: Any]
    }

    /// 返回 `playabilityStatus` 里的拦截原因；可播放时返回 nil。
    static func blockingReason(_ response: [String: Any]) -> String? {
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


}
