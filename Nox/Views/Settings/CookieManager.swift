import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState

enum CookieManager {
    struct Group: Identifiable {
        let domain: String
        let count: Int

        var id: String { domain }
    }

    /// 读取全部 Cookie，按站点域名归组（去掉前导点，`.a.com` 与 `a.com` 归为一组）。
    static func groups() async -> [Group] {
        let cookies = await allCookies()
        var counts: [String: Int] = [:]

        for cookie in cookies {
            counts[displayDomain(cookie.domain), default: 0] += 1
        }

        return counts
            .map { Group(domain: $0.key, count: $0.value) }
            .sorted { $0.domain < $1.domain }
    }

    /// 只删除某个站点的 Cookie。
    static func delete(domain: String) async {
        let store = WKWebsiteDataStore.default()
        let cookies = await allCookies().filter { displayDomain($0.domain) == domain }

        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.httpCookieStore.delete(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    /// 清空所有 Cookie（不影响本地存储、网页缓存等其它网站数据）。
    static func clearAll() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(
                ofTypes: [WKWebsiteDataTypeCookies],
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    static func displayDomain(_ domain: String) -> String {
        var value = domain
        while value.hasPrefix(".") { value.removeFirst() }
        return value.isEmpty ? domain : value
    }
}

/// 「Cookie 管理」二级页：按站点列出已保存的 Cookie，可单独删除或整体清空。
