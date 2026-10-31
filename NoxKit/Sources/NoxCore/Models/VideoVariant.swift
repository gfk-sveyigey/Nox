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

    /// 展示用清晰度：按当前 App 语言翻译已知标签（音频 / 仅视频 等）。
    public var displayQuality: String {
        translatedQualityLabel(quality)
    }

    public var displayName: String {
        let q = quality.isEmpty ? L("未知清晰度") : displayQuality
        let f = format.isEmpty ? "VIDEO" : format.uppercased()
        return "\(q) · \(f)"
    }
}
