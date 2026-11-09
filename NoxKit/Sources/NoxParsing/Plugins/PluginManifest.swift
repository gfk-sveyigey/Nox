import Foundation
import NoxCore


/// `.noxplugin` 文件头里的元数据。
///
/// 站点匹配完全由这里完成，App 不需要为了判断 `canHandle` 而启动插件运行时。
struct PluginManifest: Decodable {
    struct Match: Decodable {
        let schemes: [String]?
        let hosts: [String]
        let pathPrefixes: [String]?
        let pathRegex: [String]?
        let requiredQueryKeys: [String]?
    }

    static let supportedAPIVersion = 1

    let apiVersion: Int
    let id: String
    let name: String
    let localizedNames: [String: String]?
    let version: String
    let minAppVersion: String?
    let author: String?
    let homepage: String?
    let description: String?
    let icon: String?
    let priority: Int?
    let match: Match
    let permissions: [String]
    let network: [String]?

    private static let knownPermissions: Set<String> = [
        "page.eval",
        "page.title",
        "cookies",
        "http",
        "crypto",
        "log"
    ]

    /// App 内建解析器占用的标识。插件不能覆盖它们，否则注册表会出现重复 id。
    private static let reservedIDs: Set<String> = [
        SnifferSite.identifier,
        "youtube"
    ]

    var effectivePriority: Int { priority ?? 0 }

    var displayName: String {
        let code = AppLocale.current.identifier
        if let localized = localizedNames?[code], !localized.isEmpty {
            return localized
        }
        if let localized = localizedNames?.first(where: {
            code == $0.key || code.hasPrefix($0.key) || $0.key.hasPrefix(code)
        })?.value, !localized.isEmpty {
            return localized
        }
        return name
    }

    func canHandle(_ url: URL) -> Bool {
        matchesScheme(url) && matchesHost(url) && matchesPath(url) && matchesQuery(url)
    }

    /// 只看域名，比 `canHandle` 宽：站内首页、列表页也会被认领。
    func claimsHost(_ url: URL) -> Bool {
        guard matchesScheme(url), let host = url.host else { return false }
        return match.hosts.contains { Self.host(host, matches: $0) }
    }

    func allowsNetwork(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host else { return false }
        return (network ?? []).contains { Self.host(host, matches: $0) }
    }

    func validate() throws {
        guard apiVersion == Self.supportedAPIVersion else {
            throw PluginError.unsupportedAPIVersion(apiVersion)
        }
        guard Self.isValidID(id), !Self.reservedIDs.contains(id) else {
            throw PluginError.invalidManifest(String(format: L("插件 id 不合法或被保留：%@"), id))
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginError.invalidManifest(L("插件 name 不能为空"))
        }
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginError.invalidManifest(L("插件 version 不能为空"))
        }
        guard !match.hosts.isEmpty else {
            throw PluginError.invalidManifest(L("match.hosts 不能为空"))
        }

        let unknown = Set(permissions).subtracting(Self.knownPermissions)
        guard unknown.isEmpty else {
            throw PluginError.invalidManifest(String(format: L("未知权限：%@"), unknown.sorted().joined(separator: ", ")))
        }

        for pattern in match.pathRegex ?? [] {
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                throw PluginError.invalidManifest(String(format: L("pathRegex 不合法：%@"), pattern))
            }
        }

        for pattern in match.hosts + (network ?? []) {
            guard Self.isValidHostPattern(pattern) else {
                throw PluginError.invalidManifest(String(format: L("域名规则不合法：%@"), pattern))
            }
        }

        if let minimum = minAppVersion, !minimum.isEmpty {
            let appVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0"
            guard Self.compareVersion(appVersion, minimum) >= 0 else {
                throw PluginError.appVersionTooOld(required: minimum, current: appVersion)
            }
        }
    }

    // MARK: - 匹配

    private func matchesScheme(_ url: URL) -> Bool {
        let configured = match.schemes ?? []
        let schemes = (configured.isEmpty ? ["https"] : configured)
            .map { $0.lowercased() }
        return schemes.contains(url.scheme?.lowercased() ?? "")
    }

    private func matchesHost(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return match.hosts.contains { Self.host(host, matches: $0) }
    }

    private func matchesPath(_ url: URL) -> Bool {
        let path = url.path

        if let prefixes = match.pathPrefixes, !prefixes.isEmpty {
            guard prefixes.contains(where: { path.hasPrefix($0) }) else { return false }
        }

        if let patterns = match.pathRegex, !patterns.isEmpty {
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            let matched = patterns.contains { pattern in
                guard let expression = try? NSRegularExpression(pattern: pattern) else {
                    return false
                }
                return expression.firstMatch(in: path, range: range) != nil
            }
            guard matched else { return false }
        }

        return true
    }

    private func matchesQuery(_ url: URL) -> Bool {
        guard let required = match.requiredQueryKeys, !required.isEmpty else { return true }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let keys = Set(items.map(\.name))
        return required.allSatisfy { keys.contains($0) }
    }

    // MARK: - 校验工具

    private static func isValidID(_ value: String) -> Bool {
        guard (3...64).contains(value.count) else { return false }
        return value.range(
            of: "^[a-z0-9][a-z0-9._-]*$",
            options: .regularExpression
        ) != nil
    }

    private static func isValidHostPattern(_ value: String) -> Bool {
        guard !value.isEmpty, value != "*" else { return false }
        if value.hasPrefix("*.") {
            return value.count > 2 && !value.dropFirst(2).contains("*")
        }
        return !value.contains("*")
    }

    private static func host(_ rawHost: String, matches rawPattern: String) -> Bool {
        let host = rawHost.lowercased()
        let pattern = rawPattern.lowercased()

        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host.hasSuffix("." + suffix) && host != suffix
        }

        return host == pattern || host.hasSuffix("." + pattern)
    }

    /// 只比较数字段，忽略 `1.2.0-beta` 里的预发布后缀。
    static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { part in
            Int(String(part.prefix { $0.isNumber })) ?? 0
        }
        let right = rhs.split(separator: ".").map { part in
            Int(String(part.prefix { $0.isNumber })) ?? 0
        }
        let count = max(left.count, right.count)

        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

enum PluginError: LocalizedError {
    case invalidHeader
    case invalidManifest(String)
    case unsupportedAPIVersion(Int)
    case appVersionTooOld(required: String, current: String)
    case emptyBody
    case fileTooLarge
    case invalidSource(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return L("插件缺少有效的 NoxPlugin 元数据头。")
        case .invalidManifest(let message):
            return String(format: L("插件元数据不合法：%@"), message)
        case .unsupportedAPIVersion(let version):
            return String(format: L("不支持的插件 API 版本：%d。"), version)
        case .appVersionTooOld(let required, let current):
            return String(
                format: L("插件要求 Nox %@ 或更高版本，当前为 %@。"),
                required,
                current
            )
        case .emptyBody:
            return L("插件没有 JavaScript 代码。")
        case .fileTooLarge:
            return L("插件文件超过 512 KiB 限制。")
        case .invalidSource(let message):
            return String(format: L("插件 JavaScript 语法错误：%@"), message)
        case .executionFailed(let message):
            return String(format: L("插件执行失败：%@"), message)
        }
    }
}
