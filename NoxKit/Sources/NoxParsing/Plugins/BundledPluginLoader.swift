import Foundation
import NoxCore


/// 扫描 App 包内的 `.noxplugin`。
///
/// 把插件作为 Resources 打进 IPA，仍然保持“一个文件一个插件”；
/// 后续用户导入的插件可以复用同一套 `PluginPackage` / `ScriptSiteParser`。
@MainActor
enum BundledPluginLoader {
    static func load() -> [ScriptSiteParser] {
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

        return unique.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let package = try PluginPackage(text: text)
                LogStore.shared.info(
                    "plugin loaded \(package.manifest.id)@\(package.manifest.version) from \(url.lastPathComponent)"
                )
                return ScriptSiteParser(package: package)
            } catch {
                LogStore.shared.error(
                    "plugin load failed \(url.lastPathComponent): \(error.localizedDescription)"
                )
                return nil
            }
        }
    }
}
