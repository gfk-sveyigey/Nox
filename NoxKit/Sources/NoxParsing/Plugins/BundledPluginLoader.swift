import Foundation
import NoxCore


/// 扫描 App 包内的 `.noxplugin`。
///
/// 把插件作为 Resources 打进 IPA，仍然保持“一个文件一个插件”；
/// 后续用户导入的插件可以复用同一套 `PluginPackage` / `ScriptSiteParser`。
@MainActor
enum BundledPluginLoader {
    static func load() -> [ScriptSiteParser] {
        pluginURLs().compactMap { url in
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let package = try PluginPackage(text: text)
                LogStore.shared.info(
                    "plugin loaded \(package.manifest.id)@\(package.manifest.version) from \(url.lastPathComponent)"
                )
                return ScriptSiteParser(package: package, origin: .bundled)
            } catch {
                LogStore.shared.error(
                    "plugin load failed \(url.lastPathComponent): \(error.localizedDescription)"
                )
                return nil
            }
        }
    }

    /// 找到包内某个插件的原始文件，供设置页导出。
    static func url(for identifier: String) -> URL? {
        for url in pluginURLs() {
            guard
                let text = try? String(contentsOf: url, encoding: .utf8),
                let package = try? PluginPackage(text: text),
                package.manifest.id == identifier
            else {
                continue
            }
            return url
        }
        return nil
    }

    private static func pluginURLs() -> [URL] {
        var urls: [URL] = []
        let directories: [String?] = [nil, "Plugins", "Resources", "Resources/Plugins"]
        for subdirectory in directories {
            urls += Bundle.main.urls(
                forResourcesWithExtension: "noxplugin",
                subdirectory: subdirectory
            ) ?? []
        }

        var seen = Set<String>()
        let unique = urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }

        return unique.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
