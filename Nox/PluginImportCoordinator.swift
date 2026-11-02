import Combine
import Foundation
import UIKit
import NoxCore
import NoxParsing

/// 统一处理来自「文件」App、其他 App 的「用 Nox 打开」以及设置页文件选择器的插件导入。
@MainActor
final class PluginImportCoordinator: ObservableObject {
    static let shared = PluginImportCoordinator()

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
    /// 系统可能在同一轮启动里把同一个文件重复交给 App，短时间去重避免弹两次确认。
    private var recentlyOpenedPaths: [String: Date] = [:]
    /// 提示框还没结束时到达的文件，等当前导入处理完再继续，避免静默丢弃。
    private var queuedImportURLs: [URL] = []

    private init() {}

    func handleOpenURL(_ url: URL) {
        guard url.isFileURL else {
            LogStore.shared.error(
                "ignored non-file open url: \(url.scheme ?? "?")"
            )
            return
        }
        let path = url.standardizedFileURL.path
        let now = Date()
        recentlyOpenedPaths = recentlyOpenedPaths.filter {
            now.timeIntervalSince($0.value) < 5
        }
        if let last = recentlyOpenedPaths[path], now.timeIntervalSince(last) < 5 {
            LogStore.shared.info("duplicate file open ignored: \(url.lastPathComponent)")
            return
        }
        recentlyOpenedPaths[path] = now

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
        //
        // 不按后缀过滤 Documents/Inbox：系统把文件拷进来时可能改名或去掉
        // 后缀，真正的插件格式由 `PluginStore` 读内容校验。App Group 收件箱
        // 是分享扩展自己写的，仍按 `.noxplugin` 过滤。
        let inboxPlugins = urls.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
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
        // 任何提示框还开着时都先排队，等用户处理完当前批次再继续。
        // 不能直接丢弃：文件点按没有第二次提示，用户会以为完全没反应。
        if prompt != nil {
            LogStore.shared.info("plugin import queued: prompt is pending")
            for url in urls {
                let path = url.standardizedFileURL.path
                guard !queuedImportURLs.contains(where: {
                    $0.standardizedFileURL.path == path
                }) else { continue }
                queuedImportURLs.append(url)
            }
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
            present(
                .confirmation(
                    ImportConfirmation(
                        items: items,
                        failures: failures,
                        message: Self.confirmationMessage(items: items, failures: failures)
                    )
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
            self?.drainQueuedImports()
        }
    }

    func cancelImport(_ confirmation: ImportConfirmation) {
        prompt = nil
        LogStore.shared.info("plugin import cancelled by user")
        for item in confirmation.items {
            Self.removeTemporaryImport(at: item.url)
        }
        drainQueuedImports()
    }

    /// 结果提示被用户关闭后，继续处理排队中的文件。
    func dismissNotice(_ notice: Notice) {
        if case .notice(let current) = prompt, current.id == notice.id {
            prompt = nil
        }
        drainQueuedImports()
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
        var summaries: [String] = []
        var failures = initialFailures
        var successCount = 0
        var installedCount = 0

        for item in items {
            let url = item.url
            defer { Self.removeTemporaryImport(at: url) }

            do {
                let result = try PluginStore.shared.install(from: url)
                successCount += 1
                if result.updateKind == .installed {
                    installedCount += 1
                }

                // 一行一个结果：新插件只显示名称和版本；替换时显示版本变化。
                if let previous = result.previousVersion, previous != result.version {
                    summaries.append("\(result.name) \(previous) → \(result.version)")
                } else {
                    summaries.append("\(result.name) \(result.version)")
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

        let title: String
        if failures.isEmpty {
            if installedCount == successCount {
                title = L("插件已导入")
            } else if installedCount == 0 {
                title = L("插件已更新")
            } else {
                title = L("插件导入完成")
            }
        } else if successCount == 0 {
            title = L("插件导入失败")
        } else {
            title = L("部分插件未导入")
        }

        setNotice(
            title: title,
            message: (summaries + failures).joined(separator: "\n")
        )
    }

    // MARK: - 文案 / 清理

    private func setNotice(title: String, message: String) {
        present(.notice(Notice(title: title, message: message)))
    }

    private func present(_ prompt: Prompt) {
        self.prompt = prompt
    }

    private func drainQueuedImports() {
        guard prompt == nil, !isImporting, !queuedImportURLs.isEmpty else { return }
        let urls = queuedImportURLs
        queuedImportURLs.removeAll()
        LogStore.shared.info("plugin import dequeued: \(urls.count) file(s)")
        importFiles(urls)
    }

    private static func confirmationMessage(
        items: [ImportConfirmation.Item],
        failures: [String]
    ) -> String {
        var blocks: [String] = []

        for item in items {
            let info = item.inspection
            guard info.exists, let existingVersion = info.existingVersion else { continue }

            let oldVersion = existingVersion == "?" ? L("未知版本") : existingVersion
            let change: String
            switch info.change {
            case .upgrade: change = L("升级")
            case .downgrade: change = L("回退")
            case .same: change = L("版本相同")
            case .new: change = ""
            }

            blocks.append(
                String(
                    format: L("%@ 已存在\n%@ → %@（%@）"),
                    info.name,
                    oldVersion,
                    info.version,
                    change
                )
            )
        }

        let newCount = items.filter { !$0.inspection.exists }.count
        if newCount > 0 {
            blocks.append(String(format: L("另有 %d 个新插件将一并导入。"), newCount))
        }

        blocks.append(contentsOf: failures)
        return blocks.joined(separator: "\n\n")
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
