import CryptoKit
import Foundation
import NoxCore

extension YouTubeParser {
    // MARK: - 页面内脚本

    /// 页面里正在播放的响应 getter（比首屏的 ytInitialPlayerResponse 更新）。
    static let pagePlayerGetter =
        "(function(){var el=document.getElementById('movie_player');"
        + "return (el&&typeof el.getPlayerResponse==='function')?el.getPlayerResponse():null;})()"

    static let pageInitialGetter = "window.ytInitialPlayerResponse"

    static let pageConfigGetter =
        "(function(){var a=window.ytplayer&&window.ytplayer.config&&window.ytplayer.config.args;"
        + "var r=a&&a.raw_player_response;return r?JSON.parse(r):null;})()"

    /// 把播放器响应压缩成只含需要字段的 JSON 再带回 Swift。
    ///
    /// 完整响应动辄一两 MB（还带字幕、videoDetails 等），整份 stringify 既慢又容易在
    /// 桥接时出错；这里只挑 formats / adaptiveFormats 的直链相关字段，同时保留
    /// playabilityStatus —— 视频不可播放时也能把页面的真实原因带回来看。
    static func pageExtractScript(getter: String) -> String {
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

    static let clientVersionScript =
        "(function(){try{return (window.ytcfg&&window.ytcfg.get)"
        + "?String(window.ytcfg.get('INNERTUBE_CLIENT_VERSION')||''):'';}catch(e){return '';}})()"

    static let userAgentScript =
        "(function(){try{return navigator.userAgent||'';}catch(e){return '';}})()"

    static let visitorDataScript =
        "(function(){try{return (window.ytcfg&&window.ytcfg.get)"
        + "?String(window.ytcfg.get('VISITOR_DATA')||''):'';}catch(e){return '';}})()"

    /// 页面 ytcfg 里的 InnerTube API Key（youtubei/v1/player 的 key= 参数）。
    static let apiKeyScript =
        "(function(){try{return (window.ytcfg&&window.ytcfg.get)"
        + "?String(window.ytcfg.get('INNERTUBE_API_KEY')||''):'';}catch(e){return '';}})()"

    static func pageString(_ page: WebPageContext, script: String, fallback: String) async -> String {
        guard let value = try? await page.evaluate(script),
              let text = value as? String, !text.isEmpty else {
            return fallback
        }
        return text
    }

    static var languageHint: String {
        if let code = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init),
           !code.isEmpty {
            return code
        }
        return "en"
    }


}
