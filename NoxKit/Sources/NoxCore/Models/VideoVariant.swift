import Foundation

public struct VideoVariant: Identifiable, Codable, Hashable {
    public let id: UUID
    public let quality: String
    public let format: String
    public let url: URL

    public init(id: UUID = UUID(), quality: String, format: String, url: URL) {
        self.id = id
        self.quality = quality
        self.format = format
        self.url = url
    }

    public var displayName: String {
        let q = quality.isEmpty ? L("未知清晰度") : quality
        let f = format.isEmpty ? "VIDEO" : format.uppercased()
        return "\(q) · \(f)"
    }
}
