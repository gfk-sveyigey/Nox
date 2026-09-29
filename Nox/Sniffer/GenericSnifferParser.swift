import Foundation

/// 通用兜底解析器：在注册表里必须排最后，具体站点优先命中。
///
/// 自身不含任何站点规则，只消费注入脚本嗅探到的资源，
/// 因此对「解析视频」按钮而言，任何一个 https 页面都变为可解析。
@MainActor
final class GenericSnifferParser: VideoSiteParser {
    let identifier = "generic"
    let displayName = L("通用嗅探")

    init() {}

    /// 兜底：接受任何 http(s) 页面
    func canHandle(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }

    func parse(page: WebPageContext) async throws -> [VideoVariant] {
        // 1) 让脚本立刻重扫一遍：DOM 可能在 documentStart 之后才填充
        _ = try? await page.evaluate("window.__MS_SNIFF__ && window.__MS_SNIFF__(true)")

        // 2) 给网络钩子与播放器实例一点时间落定
        try? await Task.sleep(nanoseconds: 700_000_000)

        let variants = SnifferBridge.shared.variants()
        guard !variants.isEmpty else { throw ParserError.noVideoVariants }

        return variants
    }
}