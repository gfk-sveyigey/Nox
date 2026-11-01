import Foundation

/// 分享扩展与宿主 App 之间的 App Group 收件箱。
///
/// Apple 文档明确写着：`NSExtensionContext.open(_:)` 在 iOS 上只有
/// Today 与 iMessage 扩展受支持，Share Extension 调它并不可靠
/// （第一次可能成功，之后经常失败）。所以分享扩展先把插件写进共享容器，
/// 再尽力唤起宿主 App；即使唤起失败，用户打开 Nox 时也会自动导入。
enum SharedPluginInbox {
    static let appGroupIdentifier = "group.com.aholic.nox"
    static let directoryName = "NoxPendingPlugins"

    /// 共享容器不存在（签名未包含 App Group）时返回 nil。
    static var directoryURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return container.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 写入待导入插件。写入失败时返回 nil，调用方可以退回 URL 传参。
    static func store(_ data: Data) -> URL? {
        guard let directory = directoryURL else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("noxplugin")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("NoxShare: shared inbox write failed: %@", error.localizedDescription)
            return nil
        }
    }
}
