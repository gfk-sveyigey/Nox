import UIKit
import UniformTypeIdentifiers

/// 从系统分享面板接收网页链接，再交给 Nox 的浏览页打开。
///
/// Share Extension 没有官方的「打开宿主 App」能力，因此先尝试
/// `NSExtensionContext.open(_:)`；若系统拒绝，再走 responder chain 的兼容路径。
/// 两条路径都失败时，把链接复制到剪贴板并提示用户手动打开。
final class ShareViewController: UIViewController {
    private enum SharedPayload {
        case web(URL)
        case plugin(Data)
    }

    /// 与宿主 App 的 PluginImportCoordinator 保持一致。
    private static let pluginPasteboardType = "com.aholic.nox.plugin"

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

    private var hasStarted = false
    private var hasFinished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = NSLocalizedString("正在打开 Nox…", comment: "Share extension opening status")
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        view.addSubview(spinner)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !hasStarted else { return }
        hasStarted = true

        loadSharedPayload { [weak self] payload in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let payload else {
                    self.showFailure()
                    return
                }

                switch payload {
                case .web(let url):
                    self.openHostApp(with: url)
                case .plugin(let data):
                    self.openHostAppForPlugin(data)
                }
            }
        }
    }

    private func loadSharedPayload(completion: @escaping (SharedPayload?) -> Void) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        loadPluginData(from: providers) { [weak self] data in
            DispatchQueue.main.async {
                if let data {
                    completion(.plugin(data))
                    return
                }
                self?.loadSharedPageURL { url in
                    completion(url.map(SharedPayload.web))
                }
            }
        }
    }

    /// 分享面板可能把 `.noxplugin` 提供成文件 URL、自定义 UTI 或纯文本。
    /// 三种形式都先读成 Data，再用插件头判断，避免把普通文本误当插件。
    private func loadPluginData(
        from providers: [NSItemProvider],
        completion: @escaping (Data?) -> Void
    ) {
        let identifiers = [
            Self.pluginPasteboardType,
            UTType.fileURL.identifier,
            UTType.url.identifier,
            UTType.plainText.identifier
        ]
        var remaining = providers

        func loadNext() {
            guard !remaining.isEmpty else {
                completion(nil)
                return
            }

            let provider = remaining.removeFirst()
            guard let typeIdentifier = identifiers.first(where: {
                provider.hasItemConformingToTypeIdentifier($0)
            }) else {
                loadNext()
                return
            }

            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
                guard let self else {
                    completion(nil)
                    return
                }

                if let data = self.pluginData(from: item), self.isPluginData(data) {
                    completion(data)
                } else {
                    loadNext()
                }
            }
        }

        loadNext()
    }

    private func pluginData(from item: Any) -> Data? {
        if let data = item as? Data {
            if isPluginData(data) {
                return data
            }
            // 文件 URL 有时以 UTF-8 文本形式出现在 Data 里。
            if let value = String(data: data, encoding: .utf8),
               let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.isFileURL {
                return fileData(at: url)
            }
            return data
        }

        if let text = item as? String {
            return text.data(using: .utf8)
        }

        if let text = item as? NSAttributedString {
            return text.string.data(using: .utf8)
        }

        if let url = item as? URL {
            return fileData(at: url)
        }

        if let url = item as? NSURL {
            return fileData(at: url as URL)
        }

        return nil
    }

    private func fileData(at url: URL) -> Data? {
        guard url.isFileURL else { return nil }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return try? Data(contentsOf: url)
    }

    private func isPluginData(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let normalized = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.hasPrefix("/* ==NoxPlugin==")
    }

    private func loadSharedPageURL(completion: @escaping (URL?) -> Void) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        let urlProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        loadFirstItem(from: urlProviders, typeIdentifier: UTType.url.identifier) { [weak self] item in
            if let item, let url = self?.webURL(from: item) {
                completion(url)
                return
            }

            let textProviders = providers.filter {
                $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            }
            self?.loadFirstItem(
                from: textProviders,
                typeIdentifier: UTType.plainText.identifier
            ) { textItem in
                guard let textItem, let url = self?.webURL(from: textItem) else {
                    completion(nil)
                    return
                }
                completion(url)
            }
        }
    }

    private func loadFirstItem(
        from providers: [NSItemProvider],
        typeIdentifier: String,
        index: Int = 0,
        completion: @escaping (Any?) -> Void
    ) {
        guard index < providers.count else {
            completion(nil)
            return
        }

        providers[index].loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
            if let item {
                completion(item)
            } else {
                self?.loadFirstItem(
                    from: providers,
                    typeIdentifier: typeIdentifier,
                    index: index + 1,
                    completion: completion
                )
            }
        }
    }

    private func webURL(from item: Any) -> URL? {
        if let url = item as? URL {
            return normalizedWebURL(url.absoluteString)
        }

        if let url = item as? NSURL {
            return normalizedWebURL(url.absoluteString ?? "")
        }

        if let text = item as? String {
            return webURL(fromText: text)
        }

        if let text = item as? NSAttributedString {
            return webURL(fromText: text.string)
        }

        if let data = item as? Data,
           let text = String(data: data, encoding: .utf8) {
            return webURL(fromText: text)
        }

        return nil
    }

    private func webURL(fromText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = normalizedWebURL(trimmed) {
            return direct
        }

        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: range),
              let url = match.url
        else {
            return nil
        }

        return normalizedWebURL(url.absoluteString)
    }

    private func normalizedWebURL(_ rawValue: String) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            return nil
        }

        if !value.contains("://") {
            // 避免把普通文本或 javascript: 之类的内容当成网址。
            guard !value.contains(":"), value.contains(".") else { return nil }
            value = "https://" + value
        }

        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }

        components.scheme = scheme
        return components.url
    }

    private func openHostApp(with pageURL: URL) {
        var components = URLComponents()
        components.scheme = "nox"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "url", value: pageURL.absoluteString)
        ]

        guard let noxURL = components.url else {
            showFailure(copying: pageURL)
            return
        }

        openNoxURL(noxURL) { [weak self] in
            self?.showFailure(copying: pageURL)
        }
    }

    private func openHostAppForPlugin(_ data: Data) {
        UIPasteboard.general.setData(data, forPasteboardType: Self.pluginPasteboardType)

        guard let noxURL = URL(string: "nox://import-plugin") else {
            showFailure(
                message: NSLocalizedString(
                    "插件已复制。请打开 Nox，在「解析来源」右上角选择「从剪贴板导入插件」。",
                    comment: "Share extension plugin import fallback"
                )
            )
            return
        }

        openNoxURL(noxURL) { [weak self] in
            self?.showFailure(
                message: NSLocalizedString(
                    "插件已复制。请打开 Nox，在「解析来源」右上角选择「从剪贴板导入插件」。",
                    comment: "Share extension plugin import fallback"
                )
            )
        }
    }

    private func openNoxURL(_ url: URL, onFailure: @escaping () -> Void) {
        guard let extensionContext else {
            openUsingResponderChain(url, onFailure: onFailure)
            return
        }

        extensionContext.open(url) { [weak self] opened in
            DispatchQueue.main.async {
                guard let self else { return }

                if opened {
                    self.finish()
                } else {
                    self.openUsingResponderChain(url, onFailure: onFailure)
                }
            }
        }
    }

    private func openUsingResponderChain(_ url: URL, onFailure: @escaping () -> Void) {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.finish()
                }
                return
            }
            responder = current.next
        }

        onFailure()
    }

    private func showFailure(message: String? = nil, copying pageURL: URL? = nil) {
        guard !hasFinished else { return }

        spinner.stopAnimating()
        statusLabel.isHidden = true

        if let pageURL {
            UIPasteboard.general.string = pageURL.absoluteString
        }

        let message = message ?? (pageURL == nil
            ? NSLocalizedString("未能从分享内容中读取网页链接。", comment: "Share extension no URL")
            : NSLocalizedString(
                "链接已复制。请打开 Nox，在地址栏中粘贴并访问。",
                comment: "Share extension manual fallback"
            ))

        let alert = UIAlertController(
            title: NSLocalizedString("无法打开 Nox", comment: "Share extension failure title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("完成", comment: "Share extension failure dismiss"),
            style: .default
        ) { [weak self] _ in
            self?.finish()
        })
        present(alert, animated: true)
    }

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
