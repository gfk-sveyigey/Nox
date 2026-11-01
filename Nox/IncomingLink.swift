import Foundation

/// 把从系统或其他 App 交给 Nox 的 URL 解析成可在内置浏览器中打开的网页地址。
///
/// 支持两种入口：
/// - 直接传入 `http` / `https` 地址（便于系统后续提供该能力时无需改调用方）
/// - `nox://open?url=<百分号编码的网页地址>`
enum IncomingLink {
    static let scheme = "nox"

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
