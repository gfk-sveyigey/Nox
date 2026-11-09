import Foundation
import NoxCore


/// 插件文件来源。
enum PluginOrigin: Equatable {
    case bundled
    case imported
}


/// 把单文件 `.noxplugin` 适配成现有的 `VideoSiteParser`。
@MainActor
final class ScriptSiteParser: VideoSiteParser {
    private let package: PluginPackage
    private let origin: PluginOrigin
    private lazy var runtime = PluginRuntime(
        manifest: package.manifest,
        source: package.source
    )

    init(package: PluginPackage, origin: PluginOrigin) {
        self.package = package
        self.origin = origin
    }

    var identifier: String { package.manifest.id }
    var displayName: String { package.manifest.displayName }
    var priority: Int { package.manifest.effectivePriority }

    var isBundledPlugin: Bool { origin == .bundled }
    var isImportedPlugin: Bool { origin == .imported }
    var pluginVersion: String? { package.manifest.version }
    var pluginAuthor: String? { package.manifest.author }
    var pluginDescription: String? { package.manifest.description }

    func canHandle(_ url: URL) -> Bool {
        package.manifest.canHandle(url)
    }

    func claimsHost(_ url: URL) -> Bool {
        package.manifest.claimsHost(url)
    }

    func parse(page: WebPageContext) async throws -> [VideoVariant] {
        do {
            return try await runtime.parse(page: page)
        } catch {
            LogStore.shared.error(
                "plugin \(identifier) parse failed: \(error.localizedDescription)"
            )
            throw error
        }
    }
}
