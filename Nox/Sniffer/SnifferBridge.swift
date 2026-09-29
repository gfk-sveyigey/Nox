import Foundation
import WebKit

/// 接收注入脚本 `postMessage` 上来的资源，去重后供解析器取用。
///
/// 做成 `shared` 单例：`VideoSiteParserRegistry.all` 是静态常量，
/// 解析器无法通过初始化参数拿到实例，共享单例是最省事的接法；
/// 同时 `WKUserContentController` 会强持有 handler，单例不存在实例泄漏问题。
@MainActor
final class SnifferBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "noxSniffer"
    static let shared = SnifferBridge()

    struct Item {
        let url: URL
        /// image / video / audio / m3u8 / stream
        let kind: String
        /// dom / frame / network / player
        let source: String
        let title: String
        let isLive: Bool
    }

    /// 结果上限：超长会话不至于把内存吃满
    private let limit = 4000

    private(set) var items: [Item] = []
    private var seen = Set<String>()

    private override init() {
        super.init()
    }

    func reset() {
        items.removeAll()
        seen.removeAll()
    }

    var hasLiveStream: Bool {
        items.contains { $0.kind == "stream" || $0.isLive }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName else { return }
        guard let body = message.body as? [String: Any] else { return }
        guard let raw = body["items"] as? [[String: Any]] else { return }

        for entry in raw {
            guard let urlString = entry["url"] as? String,
                  let url = URL(string: urlString) else { continue }

            let kind = (entry["kind"] as? String) ?? "video"
            let key = "\(kind)|\(url.absoluteString)"
            guard seen.insert(key).inserted else { continue }

            items.append(
                Item(
                    url: url,
                    kind: kind,
                    source: (entry["source"] as? String) ?? "dom",
                    title: (entry["title"] as? String) ?? "",
                    isLive: (entry["live"] as? Bool) ?? false
                )
            )
        }

        if items.count > limit {
            items.removeFirst(items.count - limit)
        }
    }

    // MARK: - 对外

    /// 把嗅探结果转成 App 的清晰度列表。
    ///
    /// - Parameter kinds: 默认只要可下载的视频类资源；想连图片/音频一起暴露，
    ///   传 `["image", "video", "audio", "m3u8"]`。
    func variants(kinds: Set<String> = ["m3u8", "video"]) -> [VideoVariant] {
        items
            .filter { kinds.contains($0.kind) }
            .sorted { lhs, rhs in
                // m3u8 排前面：它由 HLSDownloader 合并，画质通常更高
                if lhs.kind != rhs.kind { return lhs.kind == "m3u8" }
                return false
            }
            .map { item in
                VideoVariant(
                    quality: Self.qualityLabel(for: item),
                    format: Self.format(for: item),
                    url: item.url
                )
            }
    }

    private static func format(for item: Item) -> String {
        if item.kind == "m3u8" { return "m3u8" }

        let ext = item.url.pathExtension.lowercased()
        return ext.isEmpty ? "mp4" : ext
    }

    private static func qualityLabel(for item: Item) -> String {
        switch item.source {
        case "player": return L("播放器提取")
        case "network": return L("网络嗅探")
        default: return L("页面嗅探")
        }
    }
}