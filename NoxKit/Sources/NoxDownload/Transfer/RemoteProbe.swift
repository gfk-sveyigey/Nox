import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - 远端探测

extension DownloadManager {
    // MARK: - 探测（Range 支持 / 总大小）

    struct ProbeResult {
        var supportsRanges: Bool
        var totalBytes: Int64?
        /// 探测失败的原因；nil = 成功拿到可用的响应。
        ///
        /// 链接失效（HTTP 4xx/5xx、返回网页）与网络抖动都归到这里，
        /// 由调用方决定提示文案 —— 关键是**不能**在失败时清掉已下载的分片。
        var error: String?
    }

    /// 用 `Range: bytes=0-0` 探一次：拿到 206 + Content-Range 就说明支持续传，
    /// 顺便取得文件总大小；返回 200 说明服务器忽略了 Range，只能整文件重下。
    ///
    /// **链接失效也算探测失败**：很久以前创建的任务，链接往往早已过期，服务器会回
    /// 403/404（或一个 200 的错误网页）。若把它当成「可下载的 200」，就会把错误页
    /// 当成视频存下来，任务还显示成功。
    static func probe(
        url: URL,
        referer: URL?,
        cookieHeader: String?,
        allowsCellularAccess: Bool
    ) async -> ProbeResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allowsCellularAccess = allowsCellularAccess
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("video/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        // URLSession.shared 带本地缓存，命中旧响应会让探测结论失真
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                return ProbeResult(supportsRanges: false, totalBytes: nil, error: L("服务器返回了无法识别的响应。"))
            }

            // 4xx / 5xx：链接失效、需要重新登录、被拒绝访问……继续只会得到错误页
            if http.statusCode >= 400 {
                return ProbeResult(
                    supportsRanges: false,
                    totalBytes: nil,
                    error: String(format: L("视频链接可能已失效（HTTP %d），请重新解析后再下载。"), http.statusCode)
                )
            }

            // 200 却返回网页：多半是登录态失效后的跳转页，同样不能当视频保存
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("text/html") {
                return ProbeResult(
                    supportsRanges: false,
                    totalBytes: nil,
                    error: L("视频链接可能已失效，请重新解析后再下载。")
                )
            }

            if http.statusCode == 206,
               let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let total = totalBytes(fromContentRange: contentRange) {
                return ProbeResult(supportsRanges: true, totalBytes: total, error: nil)
            }

            let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
            return ProbeResult(supportsRanges: false, totalBytes: length, error: nil)
        } catch {
            if !allowsCellularAccess,
               let urlError = error as? URLError,
               urlError.code == .dataNotAllowed || urlError.code == .notConnectedToInternet {
                return ProbeResult(
                    supportsRanges: false,
                    totalBytes: nil,
                    error: L("已限制为「仅无线局域网」，请连接无线局域网后重试。")
                )
            }

            return ProbeResult(
                supportsRanges: false,
                totalBytes: nil,
                error: String(format: L("无法获取文件信息：%@"), error.localizedDescription)
            )
        }
    }

    /// 解析 `Content-Range: bytes 0-0/123456`
    static func totalBytes(fromContentRange value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard total != "*" else { return nil }
        return Int64(total)
    }
}
