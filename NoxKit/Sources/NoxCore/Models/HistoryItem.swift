import Foundation

public struct HistoryItem: Identifiable, Codable {
    public let id: UUID
    public let title: String
    public let url: URL
    public let visitedAt: Date

    public init(id: UUID = UUID(), title: String, url: URL, visitedAt: Date = .now) {
        self.id = id
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
    }
}
