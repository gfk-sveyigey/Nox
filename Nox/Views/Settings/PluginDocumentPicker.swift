import Foundation
import UIKit
import UniformTypeIdentifiers
import NoxCore

/// 直接由 UIKit 呈现系统文档选择器。
///
/// 之前把 `UIDocumentPickerViewController` 塞进 SwiftUI 的 `.fileImporter`
/// 或 `.sheet`：菜单退场、sheet dismissal 与结果回调叠在一起时，会出现
/// “选中文件后点打开，什么都不发生”的时序问题。文档选择器本身就是完整
/// 的模态控制器，交给最上层控制器直接 present 最稳定。
@MainActor
final class PluginDocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = PluginDocumentPicker()

    private var onPick: (([URL]) -> Void)?
    private var onCancel: (() -> Void)?
    private weak var picker: UIDocumentPickerViewController?

    private override init() {
        super.init()
    }

    /// 呈现选择器。`onPick` 收到的是已经复制到 App 临时目录的文件副本，
    /// 调用方可以直接读取，不再依赖原文件的安全作用域。
    func present(
        onPick: @escaping ([URL]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        // 上一次 present 仍在显示时不要重复呈现；如果只是残留了一个
        // 没能成功呈现的实例，则允许重新创建。
        guard picker?.presentingViewController == nil else { return }
        guard let host = Self.topViewController() else {
            LogStore.shared.error("plugin picker: no view controller to present from")
            onCancel()
            return
        }

        self.onPick = onPick
        self.onCancel = onCancel

        // 不用插件 UTI 过滤：iCloud 里较早的文件或 UTI 尚未同步的文件
        // 会变灰，用户能看到文件却点不了“打开”。后缀由导入流程统一校验。
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data],
            asCopy: true
        )
        controller.delegate = self
        controller.allowsMultipleSelection = true
        controller.shouldShowFileExtensions = true

        picker = controller
        host.present(controller, animated: true)
        LogStore.shared.info("plugin picker presented")
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        LogStore.shared.info(
            "plugin picker picked: \(urls.map(\.lastPathComponent).joined(separator: ", "))"
        )

        let copies = urls.compactMap(Self.copyToTemporaryDirectory)
        let handler = onPick
        reset()

        // 等选择器完全收起后再弹导入结果，避免提示被模态 dismissal 吞掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            handler?(copies)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        LogStore.shared.info("plugin picker cancelled")
        let handler = onCancel
        reset()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            handler?()
        }
    }

    private func reset() {
        picker?.delegate = nil
        picker = nil
        onPick = nil
        onCancel = nil
    }

    /// 选择器返回的 URL 可能受安全作用域 / 文件协调器影响；先同步读成
    /// 自己的临时副本，避免导入时原文件已被回收或读取失败。
    private static func copyToTemporaryDirectory(_ url: URL) -> URL? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        guard let data = try? Data(contentsOf: url) else {
            LogStore.shared.error("plugin picker read failed: \(url.lastPathComponent)")
            return nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoxPluginImports", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var destination = directory
                .appendingPathComponent("NoxPluginImport-\(UUID().uuidString)")
            if !url.pathExtension.isEmpty {
                destination = destination.appendingPathExtension(url.pathExtension)
            }
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            LogStore.shared.error(
                "plugin picker copy failed: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard
            let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else {
            return nil
        }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
