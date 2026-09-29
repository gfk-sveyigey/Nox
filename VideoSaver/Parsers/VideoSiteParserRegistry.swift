import Foundation

/// 站点解析器注册表：决定某个地址交给哪个解析器处理。
///
/// 新增站点时，只需往 `default` 的列表里追加一个实例。
@MainActor
final class VideoSiteParserRegistry {
    static let `default` = VideoSiteParserRegistry(parsers: [
        PornhubParser()
        // 以后新增站点在这里追加，例如：XvideosParser(),
    ])

    private let parsers: [VideoSiteParser]

    init(parsers: [VideoSiteParser]) {
        self.parsers = parsers
    }

    func parser(for url: URL?) -> VideoSiteParser? {
        guard let url else { return nil }
        return parsers.first { $0.canHandle(url) }
    }

    /// 当前地址是否可解析（用于控制「解析视频」按钮的可用状态）。
    func canHandle(_ url: URL?) -> Bool {
        parser(for: url) != nil
    }
}