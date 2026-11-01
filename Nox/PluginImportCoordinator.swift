import Combine
import Foundation
import UIKit
import UniformTypeIdentifiers
import NoxCore
import NoxParsing

extension UTType {
    /// 与 Info.plist 的 `UTExportedTypeDeclarations` 保持一致。
    /// 不使用 `UTType(filenameExtension:)` 的兜底，避免声明缺失时
    /// 文件选择器悄悄退化成 `.data`、把所有文件都列出来。
    static let noxPlugin = UTType(exportedAs: "com.aholic.nox.plugin")
}

/// 统一处理来自「文件」App、其他 App 的「用 Nox 打开」以及设置页文件选择器的插件导入。
@MainActor
final class PluginImportCoordinator: ObservableObject {
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var notice: Notice?
    @Published private(set) var isImporting = false

    /// Share Extension 与宿主 App 没有共享容器，插件文件通过剪贴板交接。
    /// 这个类型只用于传递单文件插件，不会覆盖普通文本剪贴板内容。
    private static let pluginPasteboardType = "com.aholic.nox.plugin"

    func handleOpenURL(_ url: URL) {
        guard url.isFileURL else { return }
        importFiles([url])
    }

    /// 接收分享面板写入剪贴板的插件数据，再复用文件导入流程校验。
    func importPasteboardPlugin() {
        guard
            let data = UIPasteboard.general.data(forPasteboardType: Self.pluginPasteboardType),
            !data.isEmpty
        else {
            notice = Notice(
                title: L("插件导入失败"),
                message: L("没有找到来自分享面板的插件数据，请重新分享。")
            )
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-\(UUID().uuidString)")
            .appendingPathExtension("noxplugin")

        do {
            try data.write(to: url, options: .atomic)
            importFiles([url])
            try? FileManager.default.removeItem(at: url)
        } catch {
            report(error)
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        isImporting = true
        var installed: [String] = []
        var updated: [String] = []
        var downgraded: [String] = []
        var replaced: [String] = []
        var overriddenBundled: [String] = []
        var failures: [String] = []
        var successCount = 0
        var didUpdateExisting = false

        for url in urls {
            do {
                let result = try PluginStore.shared.install(from: url)
                successCount += 1
                if result.updateKind != .installed || result.overridesBundled {
                    didUpdateExisting = true
                }
                let summary = "\(result.name) v\(result.version) · \(result.id)"

                switch result.updateKind {
                case .installed:
                    installed.append(summary)
                case .updated:
                    updated.append(summary)
                case .replaced:
                    replaced.append(summary)
                case .downgraded:
                    if let previous = result.previousVersion {
                        downgraded.append(
                            String(
                                format: L("已回退：%@（%@ → %@）"),
                                result.name,
                                previous,
                                result.version
                            )
                        )
                    } else {
                        downgraded.append(summary)
                    }
                }

                if result.overridesBundled {
                    overriddenBundled.append(result.name)
                }
            } catch {
                LogStore.shared.error(
                    "plugin import failed \(url.lastPathComponent): \(error.localizedDescription)"
                )
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        if successCount > 0 {
            VideoSiteParserRegistry.shared.reload()
        }
        isImporting = false

        var lines: [String] = []
        lines.append(contentsOf: installed.map { String(format: L("已导入：%@"), $0) })
        lines.append(contentsOf: updated.map { String(format: L("已更新：%@"), $0) })
        lines.append(contentsOf: replaced.map { String(format: L("已更新：%@"), $0) })
        lines.append(contentsOf: downgraded)
        lines.append(contentsOf: overriddenBundled.map {
            String(
                format: L("已覆盖同名内置插件：%@。删除导入版本后会恢复内置版本。"),
                $0
            )
        })
        if !installed.isEmpty {
            lines.append(L("新插件已加入「解析来源」；如有多个解析器匹配同一站点，可在该页面调整顺序。"))
        }
        if didUpdateExisting {
            lines.append(L("同名插件按 ID 更新现有条目，不会在列表中新增重复行。"))
        }
        lines.append(contentsOf: failures)

        if successCount > 0 {
            lines.append(L("提示：当前未验证插件签名，请只导入可信来源。"))
        }

        let title: String
        if failures.isEmpty {
            if installed.count == successCount {
                title = L("插件已导入")
            } else if updated.count + downgraded.count + replaced.count == successCount {
                title = L("插件已更新")
            } else {
                title = L("插件导入完成")
            }
        } else if successCount == 0 {
            title = L("插件导入失败")
        } else {
            title = L("部分插件未导入")
        }

        notice = Notice(title: title, message: lines.joined(separator: "\n"))
    }

    func report(_ error: Error) {
        notice = Notice(
            title: L("插件导入失败"),
            message: error.localizedDescription
        )
    }
}
