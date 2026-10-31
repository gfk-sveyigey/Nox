import Foundation

/// 浏览页收藏的书签。
public struct Bookmark: Identifiable, Codable, Equatable {
    public let id: UUID
    /// 收藏时的页面标题
    public let title: String
    public let url: URL
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, url: URL, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
    }

    /// 列表标题：优先用页面标题，为空时回退到主机名。
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host ?? url.absoluteString
    }
}
