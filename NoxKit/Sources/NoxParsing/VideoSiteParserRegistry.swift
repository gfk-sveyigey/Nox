import Foundation
import NoxCore

/// 站点解析器注册表。
///
/// 新增站点时，往 `all` 里追加一个实例即可；设置页的站点开关会自动出现，
/// 不需要额外改 UI 或工程配置。
@MainActor
public final class VideoSiteParserRegistry {
    /// 全部已接入的站点（顺序即设置页展示顺序，也是匹配优先级）
    ///
    /// - `BundledPluginLoader` 先加载包内的 `.noxplugin`；
    /// - `GenericSnifferParser` 使用最低优先级，永远排在最后。
    public static let all: [VideoSiteParser] = {
        var parsers: [VideoSiteParser] = []
        parsers.append(contentsOf: BundledPluginLoader.load().map { $0 as VideoSiteParser })
        parsers.append(YouTubeParser())
        parsers.append(GenericSnifferParser())
        return parsers.sorted { $0.priority > $1.priority }
    }()

    public static let `default` = VideoSiteParserRegistry(parsers: all)

    public let parsers: [VideoSiteParser]

    public init(parsers: [VideoSiteParser]) {
        self.parsers = parsers
    }

    /// 按站点规则匹配，不考虑开关状态
    public func parser(for url: URL?) -> VideoSiteParser? {
        guard let url else { return nil }
        return parsers.first { $0.canHandle(url) }
    }
}
