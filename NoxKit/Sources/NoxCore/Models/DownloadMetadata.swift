import Foundation

/// Optional metadata: missing values mean the parser did not supply the information.
public struct DownloadMetadata: Codable, Hashable {
    public var originalPageURL: URL?
    public var parserName: String?
    public var requestHeaders: [String: String]?
    public var updateDates: [Date] = []
    public var completedAt: Date?

    public init() {}
}
