import Foundation

extension URL {
    /// 常见的跟踪参数：同一页面往往带不同的一串，逐字比较会误判成不同页。
    private static let trackingParameterNames: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "gclid", "msclkid", "igshid", "spm_id_from", "vd_source",
        "from_spmid", "share_source", "share_medium", "share_plat", "share_tag",
        "timestamp", "unique_k", "buvid"
    ]

    /// 「是否同一个页面」的归一化判定键。
    ///
    /// 大小写统一、去掉结尾斜杠与 fragment、剔除跟踪参数、参数名排序 ——
    /// 让 `https://a.com/v/` 与 `https://A.com/v?utm_source=x` 归为同一条。
    public var pageIdentity: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }

        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        // path 是 String（不是 String?），所以只能用普通变量接，不能写 `if var path = ...`
        var path = components.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
            components.path = path
        }

        if let items = components.queryItems {
            let kept = items
                .filter { !Self.trackingParameterNames.contains($0.name.lowercased()) }
                .sorted {
                    $0.name == $1.name
                        ? ($0.value ?? "") < ($1.value ?? "")
                        : $0.name < $1.name
                }

            components.queryItems = kept.isEmpty ? nil : kept
        }

        return components.string ?? absoluteString
    }
}
