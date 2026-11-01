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
        /// 导入的同 id 插件覆盖了 App 包内插件；删除导入版本后会回落到包内版本。
        public let overridesBundled: Bool

        public var isUpdate: Bool { updateKind != .installed }
    }

    public static let shared = PluginStore()

    private let fileManager = FileManager.default
    private let pluginExtension = "noxplugin"

    private init() {}

    private var pluginsDirectory: URL {
        DownloadStorage.rootDirectory.appendingPathComponent("Plugins", isDirectory: true)
    }

    // MARK: - 加载

    /// 合并包内插件与用户插件。同 id 时用户导入的版本覆盖包内版本。
    func loadParsers() -> [ScriptSiteParser] {
        var byID: [String: ScriptSiteParser] = [:]

        for parser in BundledPluginLoader.load() {
            byID[parser.identifier] = parser
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
        guard url.isFileURL, url.pathExtension.lowercased() == pluginExtension else {
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

        let destination = pluginFileURL(for: package.manifest.id)
        let existed = fileManager.fileExists(atPath: destination.path)
        let previousVersion = existed ? installedVersion(at: destination) : nil
        let overridesBundled = BundledPluginLoader.load().contains {
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
    public func exportURL(for identifier: String) -> URL? {
        let source = pluginFileURL(for: identifier)
        guard fileManager.fileExists(atPath: source.path) else { return nil }

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

    public func removeImported(identifier: String) throws {
        let url = pluginFileURL(for: identifier)
        guard fileManager.fileExists(atPath: url.path) else {
            throw PluginStoreError.notImported
        }

        try fileManager.removeItem(at: url)
        LogStore.shared.info("plugin removed \(identifier)")
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
            return L("该插件不是用户导入的插件，无法删除。")
        case .readFailed(let message):
            return String(format: L("不能读取插件文件：%@"), message)
        case .writeFailed(let message):
            return String(format: L("插件写入失败：%@"), message)
        }
    }
}
