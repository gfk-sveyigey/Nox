import Foundation
import JavaScriptCore
import NoxCore


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
            throw PluginError.invalidManifest(L("插件元数据超过 32 KiB"))
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

    /// 只编译、不执行插件脚本。
    ///
    /// `new Function(source)` 会让 JavaScriptCore 先解析并编译函数体；
    /// 这里只构造函数对象，不会运行其中的 `Nox.register(...)`，也不会触发
    /// 插件里的网络 / 页面访问。这样语法错误能在导入时直接拒绝。
    func validateJavaScriptSyntax() throws {
        guard let context = JSContext() else {
            throw PluginError.invalidSource(L("无法创建 JavaScript 语法检查器。"))
        }
        guard let constructor = context.objectForKeyedSubscript("Function") else {
            throw PluginError.invalidSource(L("JavaScript 语法检查器不可用。"))
        }

        _ = constructor.construct(withArguments: [source])

        if let exception = context.exception {
            let message = exception.toString() ?? L("未知语法错误")
            context.exception = nil
            throw PluginError.invalidSource(message)
        }
    }
}
