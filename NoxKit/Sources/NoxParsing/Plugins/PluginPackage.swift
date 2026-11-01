import Foundation


/// 解析后的单文件插件。
struct PluginPackage {
    static let maxFileBytes = 512 * 1024

    let manifest: PluginManifest
    let source: String

    init(text: String) throws {
        guard text.utf8.count <= Self.maxFileBytes else {
            throw PluginError.fileTooLarge
        }

        let headerStart = "/* ==NoxPlugin=="
        let headerEnd = "==NoxPlugin== */"
        let signatureStart = "/* ==NoxSignature=="

        guard let start = text.range(of: headerStart) else {
            throw PluginError.invalidHeader
        }

        let prefix = String(text[..<start.lowerBound])
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.isEmpty else {
            throw PluginError.invalidHeader
        }

        guard let end = text.range(of: headerEnd, range: start.upperBound..<text.endIndex) else {
            throw PluginError.invalidHeader
        }

        let json = String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard json.utf8.count <= 32 * 1024 else {
            throw PluginError.invalidManifest("元数据超过 32 KiB")
        }

        let decoded: PluginManifest
        do {
            decoded = try JSONDecoder().decode(
                PluginManifest.self,
                from: Data(json.utf8)
            )
        } catch {
            throw PluginError.invalidManifest(error.localizedDescription)
        }

        try decoded.validate()
        manifest = decoded

        var body = String(text[end.upperBound...])
        if let signature = body.range(of: signatureStart) {
            body = String(body[..<signature.lowerBound])
        }

        source = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw PluginError.emptyBody
        }
    }
}
