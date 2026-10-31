import Foundation
import NoxCore

enum MediaResourceLoader {
    static func fetch(
        url: URL,
        referer: URL?,
        cookieHeader: String?,
        userAgent: String?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")

        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ParserError.manifestRequestFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParserError.manifestRequestFailed("HTTP \(http.statusCode)")
        }

        return data
    }
}

/// 多数站点的清晰度清单都是 `[{ videoUrl, quality, format }]`，抽出来复用。
