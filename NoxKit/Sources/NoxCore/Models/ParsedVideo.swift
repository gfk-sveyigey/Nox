import Foundation

public struct ParsedVideo: Identifiable {
    public let id = UUID()
    public let title: String
    public let pageURL: URL
    public let variants: [VideoVariant]

    public init(title: String, pageURL: URL, variants: [VideoVariant]) {
        self.title = title
        self.pageURL = pageURL
        self.variants = variants
    }
}
