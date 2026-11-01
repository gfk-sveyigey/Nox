import Combine
import Foundation
import NoxCore

/// 站点解析器注册表。
///
/// 注册表是 App 生命周期内的单一实例：导入、删除插件或调整顺序后，
/// 设置页与仍在运行的 `VideoParser` 都会读取到最新列表。
@MainActor
public final class VideoSiteParserRegistry: ObservableObject {
    public static let shared = VideoSiteParserRegistry()
    public static var `default`: VideoSiteParserRegistry { shared }
    public static var all: [VideoSiteParser] { shared.parsers }

    private static let orderKey = "Nox.siteOrder"

    /// 顺序即匹配优先级：越靠前越先命中。
    @Published public private(set) var parsers: [VideoSiteParser]
    /// 解析器列表的变更序号。`@Published` 在属性写入前广播，
    /// 订阅方等到这个值变化时，`parsers` 一定已经是新数组。
    @Published public private(set) var revision = 0

    private init() {
        parsers = Self.makeParsers()
    }

    /// 重新扫描包内与用户导入的插件。导入 / 删除插件后调用。
    public func reload() {
        setParsers(Self.makeParsers())
    }

    /// 设置页拖拽排序。
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { parsers.indices.contains($0) }
        guard !valid.isEmpty else { return }

        let moving = valid.sorted().map { parsers[$0] }
        var next = parsers
        for index in valid.sorted(by: >) {
            next.remove(at: index)
        }

        let removedBeforeDestination = valid.filter { $0 < destination }.count
        let insertion = min(max(destination - removedBeforeDestination, 0), next.count)
        next.insert(contentsOf: moving, at: insertion)

        // 通用 Sniffer 会匹配所有网页，必须永远排在最后。
        if let index = next.firstIndex(where: { $0.identifier == SnifferSite.identifier }) {
            let sniffer = next.remove(at: index)
            next.append(sniffer)
        }

        setParsers(next)
        persistOrder()
    }

    public func restoreDefaultOrder() {
        UserDefaults.standard.removeObject(forKey: Self.orderKey)
        reload()
    }

    /// 按站点规则匹配，不考虑开关状态。
    public func parser(for url: URL?) -> VideoSiteParser? {
        guard let url else { return nil }
        return parsers.first { $0.canHandle(url) }
    }

    // MARK: - 装配

    private static func makeParsers() -> [VideoSiteParser] {
        var list: [VideoSiteParser] = PluginStore.shared.loadParsers().map { $0 as VideoSiteParser }
        list.append(YouTubeParser())
        list.append(GenericSnifferParser())

        let sorted = list.sorted(by: defaultSort)
        let savedOrder = (UserDefaults.standard.stringArray(forKey: orderKey) ?? [])
            .map { $0 == "generic" ? SnifferSite.identifier : $0 }
        return apply(order: savedOrder, to: sorted)
    }

    private static func defaultSort(_ lhs: VideoSiteParser, _ rhs: VideoSiteParser) -> Bool {
        if lhs.identifier == SnifferSite.identifier { return false }
        if rhs.identifier == SnifferSite.identifier { return true }

        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }

        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if comparison == .orderedSame {
            return lhs.identifier < rhs.identifier
        }
        return comparison == .orderedAscending
    }

    private static func apply(order: [String], to parsers: [VideoSiteParser]) -> [VideoSiteParser] {
        var byID: [String: VideoSiteParser] = [:]
        for parser in parsers {
            byID[parser.identifier] = parser
        }

        var result: [VideoSiteParser] = []
        for identifier in order {
            if let parser = byID.removeValue(forKey: identifier) {
                result.append(parser)
            }
        }

        result.append(contentsOf: byID.values.sorted(by: defaultSort))

        if let index = result.firstIndex(where: { $0.identifier == SnifferSite.identifier }) {
            let sniffer = result.remove(at: index)
            result.append(sniffer)
        }
        return result
    }

    private func setParsers(_ next: [VideoSiteParser]) {
        parsers = next
        revision &+= 1
    }

    private func persistOrder() {
        UserDefaults.standard.set(
            parsers.map { $0.identifier },
            forKey: Self.orderKey
        )
    }
}
