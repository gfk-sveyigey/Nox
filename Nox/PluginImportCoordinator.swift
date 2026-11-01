import Combine
import Foundation
import NoxCore
import NoxParsing

/// 统一处理来自「文件」App、其他 App 的「用 Nox 打开」以及设置页文件选择器的插件导入。
@MainActor
final class PluginImportCoordinator: ObservableObject {
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// 已存在同 ID 插件时的导入确认。等待用户选择期间，文件不会被写入。
    struct ImportConfirmation: Identifiable {
        struct Item {
            let url: URL
            let inspection: PluginStore.Inspection
        }

        let id = UUID()
        let items: [Item]
        let failures: [String]
        let message: String
    }

    enum Prompt: Identifiable {
        case notice(Notice)
        case confirmation(ImportConfirmation)

        var id: UUID {
            switch self {
            case .notice(let notice): return notice.id
            case .confirmation(let confirmation): return confirmation.id
            }
        }
    }

    @Published var prompt: Prompt?
    @Published private(set) var isImporting = false

    /// 本次运行里已经交给导入流程的文件。`Documents/Inbox` 兜底扫描用它去重。
    private var handledPaths = Set<String>()

    func handleOpenURL(_ url: URL) {
        guard url.isFileURL else {
            LogStore.shared.error(
                "ignored non-file open url: \(url.scheme ?? "?")"
            )
            return
        }
        LogStore.shared.info("open file: \(url.lastPathComponent)")
        markHandled(url)
        importFiles([url])
    }

    /// 分享扩展已按 `.noxplugin` 后缀识别并压缩插件，宿主 App 解码后
    /// 落成临时文件，再复用同一套文件校验流程。
    func importSharedPlugin(_ data: Data) {
        guard !data.isEmpty else {
            reportSharedPluginFailure()
            return
        }

        LogStore.shared.info("plugin import from share: \(data.count) bytes")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-\(UUID().uuidString)")
            .appendingPathExtension("noxplugin")

        do {
            try data.write(to: url, options: .atomic)
            importFiles([url])
        } catch {
            report(error)
        }
    }

    /// 兜底：部分 iOS 版本把「拷贝到 Nox」的文件放进 `Documents/Inbox`
    /// 却不回调 open URL。回到前台时扫一次，同一个文件只处理一次。
    func importPendingInboxPluginsIfNeeded() {
        guard !isImporting, prompt == nil else { return }

        let inbox = DownloadStorage.documentsDirectory
            .appendingPathComponent("Inbox", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        // Documents/Inbox 与 App Group 收件箱一起扫描：后者来自分享扩展，
        // 即使系统没有帮我们唤起 App 也能在下次前台时导入。
        let inboxPlugins = urls.filter { $0.pathExtension.lowercased() == "noxplugin" }
        let pending = (inboxPlugins + SharedPluginInbox.pendingPluginURLs())
            .filter { !handledPaths.contains($0.standardizedFileURL.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !pending.isEmpty else { return }

        for url in pending { markHandled(url) }
        LogStore.shared.info(
            "inbox plugins: \(pending.map(\.lastPathComponent).joined(separator: ", "))"
        )
        importFiles(pending)
    }

    /// 分享扩展只回传一个短链接时，插件本体在 App Group 收件箱里。
    func importPendingSharedPlugins() {
        let pending = SharedPluginInbox.pendingPluginURLs()
            .filter { !handledPaths.contains($0.standardizedFileURL.path) }
        guard !pending.isEmpty else {
            LogStore.shared.info("shared inbox is empty")
            setNotice(
                title: L("插件导入失败"),
                message: L("没有找到待导入的插件，请重新分享。")
            )
            return
        }

        LogStore.shared.info(
            "shared inbox plugins: \(pending.map(\.lastPathComponent).joined(separator: ", "))"
        )
        importFiles(pending)
    }

    private func markHandled(_ url: URL) {
        guard url.isFileURL else { return }
        handledPaths.insert(url.standardizedFileURL.path)
    }

    func reportSharedPluginFailure() {
        LogStore.shared.error("shared plugin payload missing or undecodable")
        setNotice(
            title: L("插件导入失败"),
            message: L("分享的插件数据无法读取，请重新分享。")
        )
    }

    func importFiles(_ urls: [URL]) {
        // 确认框还开着时不再叠加新的导入请求，避免两个批次混在一起。
        if case .confirmation = prompt {
            LogStore.shared.info("plugin import ignored: confirmation is pending")
            for url in urls { Self.removeTemporaryImport(at: url) }
            return
        }

        guard !urls.isEmpty else {
            setNotice(
                title: L("插件导入失败"),
                message: L("无法读取所选文件，请重试。")
            )
            return
        }

        LogStore.shared.info(
            "plugin import request: \(urls.map(\.lastPathComponent).joined(separator: ", "))"
        )
        for url in urls { markHandled(url) }

        var items: [ImportConfirmation.Item] = []
        var failures: [String] = []

        for url in urls {
            do {
                let inspection = try PluginStore.shared.inspect(from: url)
                items.append(.init(url: url, inspection: inspection))
            } catch {
                LogStore.shared.error(
                    "plugin inspect failed \(url.lastPathComponent): \(error.localizedDescription)"
                )
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                Self.removeTemporaryImport(at: url)
            }
        }

        guard !items.isEmpty else {
            setNotice(
                title: L("插件导入失败"),
                message: failures.joined(separator: "\n")
            )
            return
        }

        let existing = items.filter { $0.inspection.exists }
        if !existing.isEmpty {
            LogStore.shared.info(
                "plugin import needs confirmation: \(existing.map(\.inspection.id).joined(separator: ", "))"
            )
            prompt = .confirmation(
                ImportConfirmation(
                    items: items,
                    failures: failures,
                    message: Self.confirmationMessage(items: items, failures: failures)
                )
            )
            return
        }

        performImport(items, failures: failures)
    }

    /// 由 Alert 按钮直接传入确认内容：SwiftUI 可能在执行按钮动作前
    /// 先把 `prompt` 置空，不能依赖从状态里再读一次。
    func confirmImport(_ confirmation: ImportConfirmation) {
        prompt = nil
        LogStore.shared.info("plugin import confirmed by user")

        // 等确认框完全收起后再弹导入结果，避免两个 alert 抢同一个
        // presentation 被系统丢掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.performImport(confirmation.items, failures: confirmation.failures)
        }
    }

    func cancelImport(_ confirmation: ImportConfirmation) {
        prompt = nil
        LogStore.shared.info("plugin import cancelled by user")
        for item in confirmation.items {
            Self.removeTemporaryImport(at: item.url)
        }
    }

    func report(_ error: Error) {
        setNotice(
            title: L("插件导入失败"),
            message: error.localizedDescription
        )
    }

    // MARK: - 安装

    private func performImport(
        _ items: [ImportConfirmation.Item],
        failures initialFailures: [String]
    ) {
        guard !items.isEmpty else {
            setNotice(
                title: L("插件导入失败"),
                message: initialFailures.joined(separator: "\n")
            )
            return
        }

        isImporting = true
        var installed: [String] = []
        var updated: [String] = []
        var downgraded: [String] = []
        var replaced: [String] = []
        var overriddenBundled: [String] = []
        var failures = initialFailures
        var successCount = 0
        var didUpdateExisting = false

        for item in items {
            let url = item.url
            defer { Self.removeTemporaryImport(at: url) }

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
                format: L("已覆盖同名内置插件：%@。删除后不会恢复内置版本。"),
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

        setNotice(title: title, message: lines.joined(separator: "\n"))
    }

    // MARK: - 文案 / 清理

    private func setNotice(title: String, message: String) {
        prompt = .notice(Notice(title: title, message: message))
    }

    private static func confirmationMessage(
        items: [ImportConfirmation.Item],
        failures: [String]
    ) -> String {
        var lines = [
            L("以下插件已经存在。确认后会替换当前版本，无论版本升高、降低还是相同：")
        ]

        for item in items {
            let info = item.inspection
            guard let existingVersion = info.existingVersion else { continue }

            let origin = info.existing == .bundled ? L("内置") : L("已导入")
            let oldVersion = existingVersion == "?" ? L("未知版本") : existingVersion
            let change: String
            switch info.change {
            case .upgrade: change = L("升级")
            case .downgrade: change = L("回退")
            case .same: change = L("同版本")
            case .new: change = ""
            }

            lines.append(
                String(
                    format: L("%@（%@）\n%@ %@ → %@（%@）"),
                    info.name,
                    info.id,
                    origin,
                    oldVersion,
                    info.version,
                    change
                )
            )
        }

        let newCount = items.filter { !$0.inspection.exists }.count
        if newCount > 0 {
            lines.append(String(format: L("其余 %d 个新插件会一并导入。"), newCount))
        }

        lines.append(contentsOf: failures)
        return lines.joined(separator: "\n\n")
    }

    /// 清理选择器 / 分享扩展产生的临时副本。只删除本流程自己创建的
    /// 文件，不会碰用户在「文件」里的原文件。
    private static func removeTemporaryImport(at url: URL) {
        // App Group 收件箱里的副本处理完就删掉，避免下次启动重复导入。
        if SharedPluginInbox.contains(url) {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let name = url.lastPathComponent
        guard
            name.hasPrefix("NoxPluginImport-") || name.hasPrefix("shared-")
        else {
            return
        }

        let path = url.standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard path.hasPrefix(temporary) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
