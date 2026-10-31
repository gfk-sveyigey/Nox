import Foundation
import NoxCore

enum MediaManifestDecoder {
    static func variants(from data: Data) throws -> [VideoVariant] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParserError.invalidManifest
        }

        guard let items = object as? [[String: Any]] else {
            throw ParserError.invalidManifest
        }

        let variants = items.compactMap { item -> VideoVariant? in
            guard let urlString = item["videoUrl"] as? String,
                  let url = URL(string: urlString) else {
                return nil
            }

            return VideoVariant(
                quality: String(describing: item["quality"] ?? ""),
                format: String(describing: item["format"] ?? ""),
                url: url
            )
        }

        guard !variants.isEmpty else { throw ParserError.noVideoVariants }
        return variants
    }

}
