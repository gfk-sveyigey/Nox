import Foundation
import NoxCore


/// 用户导入插件的沙箱存储。
///
/// 包内插件由 `BundledPluginLoader` 读取；用户导入的插件保存在
/// `Application Support/Nox/Plugins/<id>.noxplugin`。目录不暴露给「文件」App，
/// 只通过设置页的导入 / 导出入口管理。
@MainActor
public final class PluginStore {
    public enum UpdateKind: Equatable {
        case installed
        case updated
        case downgraded
        /// 同名插件已存在：同版本重新导入，或旧文件无法解析出版本号。
        case replaced
    }

    public struct InstallResult {
        public let id: String
        public let name: String
        public let version: String
        public let previousVersion: String?
        public let updateKind: UpdateKind
        /// 导入的同 id 插件覆盖了 App 包内插件。删除导入版本时会把包内版本一并隐藏，
        /// 不会自动回落到包内版本。
        public let overridesBundled: Bool

        public var isUpdate: Bool { updateKind != .installed }
    }

    /// 导入前的只读检查结果：插件是谁、当前有没有同 ID 的版本。
    public struct Inspection {
        public enum Existing: Equatable {
            case imported
            case bundled
        }

        public enum Change: Equatable {
            case new
            case upgrade
            case downgrade
            case same
        }

        public let id: String
        public let name: String
        public let version: String
        /// 同 ID 已存在的版本号；导入版本优先，其次包内版本。
        public let existingVersion: String?
        public let existing: Existing?

        public var exists: Bool { existing != nil }

        public var change: Change {
            guard existing != nil, let existingVersion else { return .new }
            guard existingVersion != "?" else { return .same }

            let comparison = PluginManifest.compareVersion(version, existingVersion)
            if comparison > 0 { return .upgrade }
            if comparison < 0 { return .downgrade }
            return .same
        }
    }

    public static let shared = PluginStore()

    private let fileManager = FileManager.default
    private let pluginExtension = "noxplugin"
    /// 用户从本机移除的包内插件。包内文件无法真正删除，重启后仍会被扫描到，
    /// 因此这里记录 id，在装配解析器时跳过。
    private let hiddenBundledKey = "Nox.hiddenBundledPlugins"
    /// 是否显示随 App 分发的单文件插件。默认关闭，避免内置 Pornhub 之类的
    /// 插件占着解析来源；在设置页连续点击标题十次可以恢复。
    private let bundledEnabledKey = "Nox.bundledPluginsEnabled"

    private init() {}

    /// 包内单文件插件默认不显示，只有用户显式恢复后才参与装配。
    public var showsBundledPlugins: Bool {
        UserDefaults.standard.bool(forKey: bundledEnabledKey)
    }

    private var pluginsDirectory: URL {
        DownloadStorage.rootDirectory.appendingPathComponent("Plugins", isDirectory: true)
    }

    // MARK: - 加载

    /// 合并包内插件与用户插件。同 id 时用户导入的版本覆盖包内版本。
    func loadParsers() -> [ScriptSiteParser] {
        var byID: [String: ScriptSiteParser] = [:]

        if showsBundledPlugins {
            let hidden = hiddenBundledIDs
            for parser in BundledPluginLoader.load() where !hidden.contains(parser.identifier) {
                byID[parser.identifier] = parser
            }
        }

        for parser in loadImportedParsers() {
            if let bundled = byID[parser.identifier] {
                LogStore.shared.info(
                    "plugin override \(bundled.identifier)@\(bundled.pluginVersion ?? "?") with imported@\(parser.pluginVersion ?? "?")"
                )
            }
            byID[parser.identifier] = parser
        }

        return Array(byID.values)
    }

    private func loadImportedParsers() -> [ScriptSiteParser] {
        guard fileManager.fileExists(atPath: pluginsDirectory.path) else { return [] }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: pluginsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            LogStore.shared.error("plugin directory read failed: \(error.localizedDescription)")
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == pluginExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let package = try PluginPackage(text: text)
                    LogStore.shared.info(
                        "plugin loaded \(package.manifest.id)@\(package.manifest.version) from imported \(url.lastPathComponent)"
                    )
                    return ScriptSiteParser(package: package, origin: .imported)
                } catch {
                    LogStore.shared.error(
                        "imported plugin load failed \(url.lastPathComponent): \(error.localizedDescription)"
                    )
                    return nil
                }
            }
    }

    // MARK: - 导入 / 导出 / 删除

    /// 校验并保存一个插件文件。导入阶段只解析元数据并编译脚本语法，不执行插件 JavaScript。
    ///
    /// 文件来自「文件」App、iCloud Drive 或其他 App 时可能带安全作用域，
    /// 这里用 `NSFileCoordinator` 读取，避免 File Provider 尚未同步完时拿到半个文件。
    public func install(from url: URL) throws -> InstallResult {
        let (package, data) = try loadPackage(at: url)

        let destination = pluginFileURL(for: package.manifest.id)
        let existed = fileManager.fileExists(atPath: destination.path)
        let previousVersion = existed ? installedVersion(at: destination) : nil
        let overridesBundled = showsBundledPlugins && BundledPluginLoader.load().contains {
            $0.identifier == package.manifest.id
        }

        let updateKind: UpdateKind
        if !existed {
            updateKind = .installed
        } else if let previousVersion {
            let comparison = PluginManifest.compareVersion(
                package.manifest.version,
                previousVersion
            )
            if comparison < 0 {
                updateKind = .downgraded
            } else if comparison == 0 {
                updateKind = .replaced
            } else {
                updateKind = .updated
            }
        } else {
            updateKind = .replaced
        }

        do {
            try fileManager.createDirectory(
                at: pluginsDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            throw PluginStoreError.writeFailed(error.localizedDescription)
        }

        // iOS 把「用 Nox 打开」的临时副本放在 Documents/Inbox；安装成功后清掉，
        // 避免同一文件在「文件」App 里一直堆着。原地打开的源文件不会走这里。
        removeInboxCopyIfNeeded(at: url)

        let action: String
        switch updateKind {
        case .installed: action = "installed"
        case .updated: action = "updated"
        case .downgraded: action = "downgraded"
        case .replaced: action = "replaced"
        }
        let replacement = overridesBundled ? " (overrides bundled)" : ""
        LogStore.shared.info(
            "plugin \(action) \(package.manifest.id)@\(package.manifest.version)\(replacement)"
        )

        return InstallResult(
            id: package.manifest.id,
            name: package.manifest.displayName,
            version: package.manifest.version,
            previousVersion: previousVersion,
            updateKind: updateKind,
            overridesBundled: overridesBundled
        )
    }

    /// 只读取并校验，不写入磁盘。用于导入前询问用户是否覆盖已存在的插件。
    public func inspect(from url: URL) throws -> Inspection {
        let (package, _) = try loadPackage(at: url)

        let importedURL = pluginFileURL(for: package.manifest.id)
        let importedExists = fileManager.fileExists(atPath: importedURL.path)
        let bundledVersion = showsBundledPlugins
            ? BundledPluginLoader.load()
                .first { $0.identifier == package.manifest.id }?
                .pluginVersion
            : nil

        let existingVersion: String?
        let existing: Inspection.Existing?

        if importedExists {
            existingVersion = installedVersion(at: importedURL) ?? "?"
            existing = .imported
        } else if let bundledVersion {
            existingVersion = bundledVersion
            existing = .bundled
        } else {
            existingVersion = nil
            existing = nil
        }

        return Inspection(
            id: package.manifest.id,
            name: package.manifest.displayName,
            version: package.manifest.version,
            existingVersion: existingVersion,
            existing: existing
        )
    }

    private func loadPackage(at url: URL) throws -> (package: PluginPackage, data: Data) {
        // 不强制要求 `.noxplugin` 后缀：从其他 App 打开时，系统可能把文件
        // 复制/重命名成没有后缀的临时副本。真正的校验由元数据头与字段完成。
        guard url.isFileURL else {
            throw PluginStoreError.notPluginFile
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let data = try readPluginData(at: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PluginStoreError.notUTF8
        }

        let package = try PluginPackage(text: text)
        try package.validateJavaScriptSyntax()
        return (package, data)
    }

    private func readPluginData(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?

        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                )
                guard values.isRegularFile != false else {
                    throw PluginStoreError.notRegularFile
                }
                if let size = values.fileSize, size > PluginPackage.maxFileBytes {
                    throw PluginError.fileTooLarge
                }

                let data = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
                guard data.count <= PluginPackage.maxFileBytes else {
                    throw PluginError.fileTooLarge
                }
                readResult = .success(data)
            } catch {
                readResult = .failure(error)
            }
        }

        if let coordinationError {
            throw PluginStoreError.readFailed(coordinationError.localizedDescription)
        }
        guard let readResult else {
            throw PluginStoreError.readFailed(L("文件协调器没有返回可读取的插件副本。"))
        }
        return try readResult.get()
    }

    private func installedVersion(at url: URL) -> String? {
        guard
            let data = fileManager.contents(atPath: url.path),
            let text = String(data: data, encoding: .utf8),
            let package = try? PluginPackage(text: text)
        else {
            return nil
        }
        return package.manifest.version
    }

    private func removeInboxCopyIfNeeded(at url: URL) {
        let inbox = DownloadStorage.documentsDirectory
            .appendingPathComponent("Inbox", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let source = url
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let prefix = inbox.path.hasSuffix("/") ? inbox.path : inbox.path + "/"

        guard source.path.hasPrefix(prefix) else { return }
        try? fileManager.removeItem(at: source)
    }

    /// 导出时复制到临时目录，避免分享面板直接暴露 Application Support 路径。
    ///
    /// 用户导入的同 id 插件优先；没有导入版本时回落到 App 包内的单文件插件。
    public func exportURL(for identifier: String) -> URL? {
        let imported = pluginFileURL(for: identifier)
        let source: URL
        if fileManager.fileExists(atPath: imported.path) {
            source = imported
        } else if let bundled = BundledPluginLoader.url(for: identifier) {
            source = bundled
        } else {
            return nil
        }

        do {
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("NoxPluginExports", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            return destination
        } catch {
            LogStore.shared.error(
                "plugin export failed \(identifier): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// 从本机移除插件。
    ///
    /// 有用户导入的版本时删除文件，并同时隐藏同 ID 的包内版本——否则删除后
    /// 包内版本会立刻重新出现，看起来像没删掉。只有包内版本时把 id 记入
    /// 隐藏列表，因为 App 包在运行期不可写。调用方 reload 后列表会刷新。
    public func removePlugin(identifier: String) throws {
        let url = pluginFileURL(for: identifier)
        let bundledExists = BundledPluginLoader.url(for: identifier) != nil

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            if bundledExists { hideBundledPlugin(identifier) }
            LogStore.shared.info("plugin removed \(identifier)")
            return
        }

        guard bundledExists else {
            throw PluginStoreError.notImported
        }

        hideBundledPlugin(identifier)
        LogStore.shared.info("bundled plugin hidden \(identifier)")
    }

    /// 重新显示全部包内插件：打开总开关并清掉逐个删除的记录。
    public func restoreBundledPlugins() {
        UserDefaults.standard.set(true, forKey: bundledEnabledKey)
        UserDefaults.standard.removeObject(forKey: hiddenBundledKey)
        LogStore.shared.info("bundled plugins restored")
    }

    private func hideBundledPlugin(_ identifier: String) {
        var hidden = hiddenBundledIDs
        guard hidden.insert(identifier).inserted else { return }
        UserDefaults.standard.set(hidden.sorted(), forKey: hiddenBundledKey)
    }

    private var hiddenBundledIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenBundledKey) ?? [])
    }

    private func pluginFileURL(for identifier: String) -> URL {
        pluginsDirectory.appendingPathComponent("\(identifier).\(pluginExtension)")
    }
}


public enum PluginStoreError: LocalizedError {
    case notPluginFile
    case notRegularFile
    case notUTF8
    case notImported
    case readFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notPluginFile:
            return L("不是有效的 .noxplugin 文件。")
        case .notRegularFile:
            return L("插件路径不是普通文件。")
        case .notUTF8:
            return L("插件文件不是 UTF-8 文本。")
        case .notImported:
            return L("找不到该插件文件，无法删除。")
        case .readFailed(let message):
            return String(format: L("不能读取插件文件：%@"), message)
        case .writeFailed(let message):
            return String(format: L("插件写入失败：%@"), message)
        }
    }
}
