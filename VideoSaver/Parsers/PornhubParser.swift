import Foundation

/// Pornhub / Pornhub Premium 的解析实现。
@MainActor
final class PornhubParser: VideoSiteParser {
    let displayName = "Pornhub"

    private static let hosts = ["pornhub.com", "pornhubpremium.com"]

    func canHandle(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }

        guard Self.hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            return false
        }

        guard url.path == "/view_video.php" else { return false }

        return queryValue("viewkey", in: url)?.isEmpty == false
    }

    func parse(page: WebPageContext) async throws -> [VideoVariant] {
        let definitions = try await mediaDefinitions(on: page)

        guard let remote = definitions.first(where: isRemote),
              let address = remote["videoUrl"] as? String,
              let manifestURL = URL(string: address) else {
            throw ParserError.noRemoteManifest
        }

        let data = try await MediaResourceLoader.fetch(
            url: manifestURL,
            referer: page.pageURL,
            cookieHeader: await page.cookieHeader(matching: page.pageURL),
            userAgent: page.userAgent
        )

        return try MediaManifestDecoder.variants(from: data)
    }

    // MARK: - 私有

    private func isRemote(_ definition: [String: Any]) -> Bool {
        if let value = definition["remote"] as? Bool { return value }
        if let value = definition["remote"] as? String { return value == "true" }
        return false
    }

    private func mediaDefinitions(on page: WebPageContext) async throws -> [[String: Any]] {
        let script = #"""
        (() => {
          const keys = Object.getOwnPropertyNames(window).filter(k => k.startsWith('flashvars_'));
          if (!keys.length) return {error: 'no_flashvars'};
          for (const key of keys) {
            try {
              const value = window[key];
              if (value && Array.isArray(value.mediaDefinitions)) {
                return {mediaDefinitions: value.mediaDefinitions};
              }
            } catch (_) {}
          }
          return {error: 'no_mediaDefinitions'};
        })()
        """#

        let value = try await page.evaluate(script)

        guard let payload = value as? [String: Any],
              payload["error"] == nil,
              let definitions = payload["mediaDefinitions"] as? [[String: Any]] else {
            throw ParserError.noMediaDefinitions
        }

        return definitions
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}