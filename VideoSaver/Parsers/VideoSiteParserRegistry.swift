import Foundation

/// 站点解析器注册表。
///
/// 新增站点时，往 `all` 里追加一个实例即可；设置页的站点开关会自动出现，
/// 不需要额外改 UI 或工程配置。
@MainActor
final class VideoSiteParserRegistry {
    /// 全部已接入的站点（顺序即设置页展示顺序）
    static let all: [VideoSiteParser] = [
        PornhubParser()
    ]

    static let `default` = VideoSiteParserRegistry(parsers: all)

    let parsers: [VideoSiteParser]

    init(parsers: [VideoSiteParser]) {
        self.parsers = parsers
    }

    /// 按站点规则匹配，不考虑开关状态
    func parser(for url: URL?) -> VideoSiteParser? {
        guard let url else { return nil }
        return parsers.first { $0.canHandle(url) }
    }
}