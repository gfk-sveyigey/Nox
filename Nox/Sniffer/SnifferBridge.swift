import Foundation
import WebKit

/// 接收注入脚本 `postMessage` 上来的资源。
///
/// 做成 `ObservableObject` 单例：视图直接观察它，嗅探结果变化时列表自动重绘，
/// 不需要轮询；`WKUserContentController` 会强持有 handler，单例不存在实例泄漏问题。
@MainActor
final class SnifferBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    static let handlerName = "noxSniffer"
    static let shared = SnifferBridge()

    struct Item: Identifiable, Hashable {
        /// "\(kind)|\(url)"，同时用于去重与 List 的身份标识
        let id: String
        let url: URL
        /// image / video / audio / m3u8 / stream
        let kind: String
        /// dom / frame / network / player
        let source: String
        let title: String
        let isLive: Bool

        /// 落盘用的扩展名
        var format: String {
            if kind == "m3u8" { return "m3u8" }
            let ext = url.pathExtension.lowercased()
            return ext.isEmpty ? "mp4" : ext
        }

        /// 复用「清晰度」那一列显示嗅探来源
        var qualityLabel: String {
            switch source {
            case "player": return L("播放器提取")
            case "network": return L("网络嗅探")
            default: return L("页面嗅探")
            }
        }

        /// 列表标题：优先用脚本上报的标题，退回文件名 / 域名
        var displayTitle: String {
            if !title.isEmpty { return title }
            let name = url.lastPathComponent
            if !name.isEmpty { return name }
            return url.host ?? url.absoluteString
        }

        var systemImage: String {
            switch kind {
            case "image": return "photo"
            case "audio": return "waveform"
            case "m3u8": return "dot.radiowaves.left.and.right"
            default: return "play.rectangle"
            }
        }
    }

    /// 结果上限：超长会话不至于把内存吃满
    private let limit = 4000

    @Published private(set) var items: [Item] = []
    private var seen = Set<String>()

    private override init() {
        super.init()
    }

    /// 导航开始时清空上一页结果
    func reset() {
        guard !items.isEmpty || !seen.isEmpty else { return }
        items.removeAll()
        seen.removeAll()
    }

    var hasLiveStream: Bool {
        items.contains { $0.kind == "stream" || $0.isLive }
    }

    func items(matching kinds: Set<String>) -> [Item] {
        items.filter { kinds.contains($0.kind) }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName else { return }
        guard let body = message.body as? [String: Any] else { return }
        guard let raw = body["items"] as? [[String: Any]] else { return }

        var appended: [Item] = []

        for entry in raw {
            guard let urlString = entry["url"] as? String,
                  let url = URL(string: urlString) else { continue }

            let kind = (entry["kind"] as? String) ?? "video"
            let id = "\(kind)|\(url.absoluteString)"
            guard seen.insert(id).inserted else { continue }

            appended.append(
                Item(
                    id: id,
                    url: url,
                    kind: kind,
                    source: (entry["source"] as? String) ?? "dom",
                    title: (entry["title"] as? String) ?? "",
                    isLive: (entry["live"] as? Bool) ?? false
                )
            )
        }

        guard !appended.isEmpty else { return }

        items.append(contentsOf: appended)

        if items.count > limit {
            let overflow = items.count - limit
            items.removeFirst(overflow)
        }
    }

    // MARK: - 给解析器用

    /// 把嗅探结果转成 App 的清晰度列表（「解析视频」按钮走这条）
    func variants(kinds: Set<String> = ["m3u8", "video", "stream"]) -> [VideoVariant] {
        items
            .filter { kinds.contains($0.kind) }
            .sorted { Self.rank($0.kind) < Self.rank($1.kind) }
            .map { VideoVariant(quality: $0.qualityLabel, format: $0.format, url: $0.url) }
    }

    /// m3u8 优先：它由 HLSDownloader 合并，画质通常更高
    private static func rank(_ kind: String) -> Int {
        switch kind {
        case "m3u8": return 0
        case "video": return 1
        case "stream": return 2
        case "audio": return 3
        case "image": return 4
        default: return 5
        }
    }
}