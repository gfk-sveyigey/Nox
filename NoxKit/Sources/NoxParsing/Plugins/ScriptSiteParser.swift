import Foundation
import NoxCore


/// 把单文件 `.noxplugin` 适配成现有的 `VideoSiteParser`。
@MainActor
final class ScriptSiteParser: VideoSiteParser {
    private let package: PluginPackage
    private lazy var runtime = PluginRuntime(
        manifest: package.manifest,
        source: package.source
    )

    init(package: PluginPackage) {
        self.package = package
    }

    var identifier: String { package.manifest.id }
    var displayName: String { package.manifest.displayName }
    var priority: Int { package.manifest.effectivePriority }

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
