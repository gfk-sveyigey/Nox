import Foundation

/// 与分享扩展共享的 App Group 收件箱。
///
/// 分享扩展在唤起宿主 App 之前先把插件写进这里，因此即使系统拒绝
/// `NSExtensionContext.open`（Apple 文档：iOS 只有 Today / iMessage 扩展支持），
/// 用户下次打开 Nox 时仍会自动导入。
enum SharedPluginInbox {
    static let appGroupIdentifier = "group.com.aholic.nox"
    static let directoryName = "NoxPendingPlugins"

    /// 签名未包含 App Group 时返回 nil。
    static var directoryURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return container.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// App Group 是否真正可用（签名没带能力时为 false）。
    static var isAvailable: Bool { directoryURL != nil }

    /// 收件箱里待导入的插件，按文件名排序保证顺序稳定。
    static func pendingPluginURLs() -> [URL] {
        guard let directory = directoryURL else { return [] }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "noxplugin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func contains(_ url: URL) -> Bool {
        guard let path = directoryURL?.standardizedFileURL.path else { return false }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return url.standardizedFileURL.path.hasPrefix(prefix)
    }
}
