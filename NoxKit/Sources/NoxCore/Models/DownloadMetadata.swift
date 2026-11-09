import Foundation

/// Optional metadata: missing values mean the parser did not supply the information.
public struct DownloadMetadata: Codable, Hashable {
    public var originalPageURL: URL?
    public var finalPageURL: URL?
    public var normalizedPageURL: URL?
    public var normalizationRule: String?
    public var parserName: String?
    public var parsingMethod: String?
    public var videoID: String?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var frameRate: Double?
    public var bitrate: Int64?
    public var audioLanguage: String?
    public var subtitleLanguage: String?
    public var requestHeaders: [String: String]?
    public var updateDates: [Date] = []
    public var completedAt: Date?

    public init() {}
}

/// Only explicit site-scoped rules may rewrite a source URL. No universal language stripping.
public struct SourceURLNormalizationRule {
    public let identifier: String
    public let host: String
    public let pattern: String
    public let replacement: String

    public init(identifier: String, host: String, pattern: String, replacement: String) {
        self.identifier = identifier
        self.host = host
        self.pattern = pattern
        self.replacement = replacement
    }

    public func normalize(_ url: URL) -> URL? {
        guard url.host?.lowercased() == host.lowercased(),
              let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = url.absoluteString
        let range = NSRange(source.startIndex..., in: source)
        guard regex.firstMatch(in: source, range: range) != nil else { return nil }
        let result = regex.stringByReplacingMatches(in: source, range: range, withTemplate: replacement)
        guard let normalized = URL(string: result), normalized.host == url.host else { return nil }
        return normalized
    }
}
