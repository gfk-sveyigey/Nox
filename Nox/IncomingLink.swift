import Foundation

/// 把从系统或其他 App 交给 Nox 的 URL 解析成可在内置浏览器中打开的网页地址。
///
/// 支持两种入口：
/// - 直接传入 `http` / `https` 地址（便于系统后续提供该能力时无需改调用方）
/// - `nox://open?url=<百分号编码的网页地址>`
enum IncomingLink {
    static let scheme = "nox"

    /// 分享扩展把压缩后的插件数据放进这个地址，唤起宿主 App。
    static func isPluginImport(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return false
        }
        return components.host?.lowercased() == "import-plugin"
    }

    /// 链接里是否真的带了插件内容（旧版分享扩展的传参方式）。
    static func hasInlinePluginData(_ url: URL) -> Bool {
        guard isPluginImport(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return false
        }
        return components.queryItems?.contains {
            $0.name.lowercased() == "data" && !($0.value ?? "").isEmpty
        } ?? false
    }

    /// 解码分享扩展通过 `nox://import-plugin?data=...` 传来的插件。
    /// 数据使用 URL-safe Base64 编码，避免原文中的换行和 `+` / `/` 破坏 URL。
    static func pluginData(from url: URL) -> Data? {
        guard isPluginImport(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = components.queryItems?
                .first(where: { $0.name.lowercased() == "data" })?
                .value,
              !encoded.isEmpty
        else {
            return nil
        }

        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64) else { return nil }

        // 分享扩展会先做 zlib 压缩再编码，减少自定义 URL 的长度；
        // 未压缩的旧链接仍然兼容。
        let compressed = components.queryItems?
            .first(where: { $0.name.lowercased() == "compressed" })?
            .value == "1"
        guard compressed else { return data }

        return try? (data as NSData).decompressed(using: .zlib) as Data
    }

    static func webURL(from url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }

        if scheme == "http" || scheme == "https" {
            return normalizedWebURL(url.absoluteString)
        }

        guard scheme == Self.scheme else { return nil }
        return webURL(fromNoxURL: url)
    }

    private static func webURL(fromNoxURL url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "open"
        else {
            return nil
        }

        guard let target = components.queryItems?
            .first(where: { $0.name.lowercased() == "url" })?
            .value
        else {
            return nil
        }

        return normalizedWebURL(target)
    }

    private static func normalizedWebURL(_ rawValue: String) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // 允许调用方省略 scheme；外部 App 传入完整链接时保持原样。
        if !value.contains("://") {
            value = "https://" + value
        }

        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }

        components.scheme = scheme
        return components.url
    }
}
