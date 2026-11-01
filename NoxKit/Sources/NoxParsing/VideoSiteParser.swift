import Foundation
import WebKit
import NoxCore


/// 单个视频站点的解析规则。
///
/// 新增站点：实现本协议 → 在 `VideoSiteParserRegistry.all` 里注册一行即可。
/// 不需要改动 `VideoParser`、`VideoBrowserView` 等任何调用方。
@MainActor
public protocol VideoSiteParser: AnyObject {
    /// 稳定标识，用于持久化「站点开关」。
    /// 一经发布就不要改，否则用户已保存的开关状态会失效。
    var identifier: String { get }

    /// 匹配优先级：数值越大越先命中。通用 Sniffer 使用负数，永远垫底。
    var priority: Int { get }

    /// 站点展示名，用于设置页与调试提示
    var displayName: String { get }

    /// 是否由本解析器处理该地址（同时决定「解析视频」入口是否可用）
    func canHandle(_ url: URL) -> Bool

    /// 该地址是否落在本站点管辖范围内（只看域名，比 canHandle 宽）。
    ///
    /// canHandle 只对「可解析的具体页面」返回 true（例如 Pornhub 只认
    /// view_video.php），但站点的首页、列表页同样是站内页面 —— 这些页面
    /// 会回落到通用嗅探。视图层用本方法判断「是否站在某个已知站点上」，
    /// 从而避免站内页面同时出现「解析视频」与通用嗅探两个入口。
    func claimsHost(_ url: URL) -> Bool

    /// 在当前页面上抓取可下载的清晰度列表；失败时抛 `ParserError`
    func parse(page: WebPageContext) async throws -> [VideoVariant]
}

extension VideoSiteParser {
    /// 普通站点默认优先级；需要覆盖其它解析器的插件可在 manifest 里声明更高值。
    public var priority: Int { 0 }
}

extension WebPageContext {
    /// 默认退回同步执行；支持异步通道的实现（`WKWebPageContext`）会覆盖它。
    public func evaluateAsync(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await evaluate(body)
    }
}
