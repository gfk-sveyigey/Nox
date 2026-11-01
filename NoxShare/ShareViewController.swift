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
        /// 分享的是文件，但后缀不是 `.noxplugin`。
        case invalidFile
        /// 看起来是插件文件，但没能读取内容。
        case unreadablePlugin
    }

    /// 与宿主 App 的 Info.plist / 插件文件类型保持一致。
    private static let pluginTypeIdentifier = "com.aholic.nox.plugin"

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
                case .invalidFile:
                    self.showFailure(
                        message: NSLocalizedString(
                            "这个文件不是 Nox 插件。请分享 .noxplugin 插件文件，或网页链接。",
                            comment: "Share extension non-plugin file"
                        )
                    )
                case .unreadablePlugin:
                    self.showPluginFailure()
                }
            }
        }
    }

    private func loadSharedPayload(completion: @escaping (SharedPayload?) -> Void) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        loadPluginData(from: providers) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }

                if let data {
                    completion(.plugin(data))
                    return
                }

                // 明确分享的是文件时，不再把它当网页链接解析，
                // 否则只会得到含糊的“未能读取网页链接”。
                switch self.sharedFileKind(providers) {
                case .plugin?:
                    completion(.unreadablePlugin)
                    return
                case .other?:
                    completion(.invalidFile)
                    return
                case nil:
                    break
                }

                self.loadSharedPageURL { url in
                    completion(url.map(SharedPayload.web))
                }
            }
        }
    }

    /// 分享面板可能把 `.noxplugin` 提供成文件 URL、自定义 UTI 或纯文本。
    /// 优先看文件名后缀；没有文件名时再用插件头兜底，普通网页文本不会被误判。
    private func loadPluginData(
        from providers: [NSItemProvider],
        completion: @escaping (Data?) -> Void
    ) {
        let identifiers = [
            Self.pluginTypeIdentifier,
            UTType.fileURL.identifier,
            UTType.data.identifier,
            UTType.plainText.identifier
        ]
        var providerIndex = 0

        // 同一个提供方可能同时声明插件 UTI、file-url 和 plain-text。
        // 某种表示加载失败时，要继续尝试它的下一种表示，而不是直接跳过
        // 这个附件——否则“文件明明在，却什么都没读到”。
        func loadProvider() {
            guard providerIndex < providers.count else {
                completion(nil)
                return
            }

            let provider = providers[providerIndex]
            providerIndex += 1

            let types = identifiers.filter {
                provider.hasItemConformingToTypeIdentifier($0)
            }
            guard !types.isEmpty else {
                loadProvider()
                return
            }

            var typeIndex = 0
            func loadType() {
                guard typeIndex < types.count else {
                    loadProvider()
                    return
                }

                let typeIdentifier = types[typeIndex]
                typeIndex += 1

                provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
                    guard let self else {
                        completion(nil)
                        return
                    }

                    if let data = self.pluginData(from: item, provider: provider) {
                        completion(data)
                    } else {
                        loadType()
                    }
                }
            }

            loadType()
        }

        loadProvider()
    }

    private func pluginData(from item: Any, provider: NSItemProvider) -> Data? {
        let declaredPlugin = provider.hasItemConformingToTypeIdentifier(
            Self.pluginTypeIdentifier
        )
        let namedPlugin = isPluginName(provider.suggestedName)

        if let url = fileURL(from: item) {
            // 插件判定以文件后缀为准；只有系统或提供方明确标注了
            // 自定义 UTI 时才允许没有扩展名的文件。
            guard
                declaredPlugin || namedPlugin || isPluginName(url.lastPathComponent)
            else {
                return nil
            }
            return fileData(at: url)
        }

        guard let data = data(from: item) else { return nil }
        guard declaredPlugin || namedPlugin || isPluginData(data) else {
            return nil
        }
        return data
    }

    private enum SharedFileKind {
        case plugin
        case other
    }

    /// 判断分享内容里是否包含文件附件。
    ///
    /// 只在提供方明确给出 `public.file-url` 时才认定是“文件”，避免把
    /// 网页链接的 suggestedName（例如 example.com）误判成文件。
    private func sharedFileKind(_ providers: [NSItemProvider]) -> SharedFileKind? {
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let name = provider.suggestedName, isPluginName(name) {
                return .plugin
            }
            // 文件名丢失时无法按后缀判断，按插件读取失败处理更贴近实际。
            if provider.suggestedName == nil {
                return .plugin
            }
            return .other
        }
        return nil
    }

    private func fileURL(from item: Any) -> URL? {
        if let url = item as? URL {
            return url.isFileURL ? url : nil
        }
        if let url = item as? NSURL {
            let value = url as URL
            return value.isFileURL ? value : nil
        }
        if let data = item as? Data,
           let value = String(data: data, encoding: .utf8),
           let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.isFileURL {
            return url
        }
        if let value = item as? String,
           let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.isFileURL {
            return url
        }
        return nil
    }

    private func data(from item: Any) -> Data? {
        if let data = item as? Data {
            return data
        }
        if let text = item as? String {
            return text.data(using: .utf8)
        }
        if let text = item as? NSAttributedString {
            return text.string.data(using: .utf8)
        }
        return nil
    }

    private func isPluginName(_ name: String?) -> Bool {
        name?.lowercased().hasSuffix(".noxplugin") == true
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
        // 先压缩：自定义 URL 太长会被系统拒绝打开，单文件插件通常能
        // 压缩到原来的几分之一。
        var payload = data
        var compressed = false
        if let packed = try? (data as NSData).compressed(using: .zlib) as Data,
           packed.count < data.count {
            payload = packed
            compressed = true
        }

        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var components = URLComponents()
        components.scheme = "nox"
        components.host = "import-plugin"
        var items = [URLQueryItem(name: "data", value: encoded)]
        if compressed {
            items.append(URLQueryItem(name: "compressed", value: "1"))
        }
        components.queryItems = items

        guard let noxURL = components.url,
              noxURL.absoluteString.utf8.count <= 180_000
        else {
            showPluginFailure()
            return
        }

        openNoxURL(noxURL) { [weak self] in
            self?.showPluginFailure()
        }
    }

    private func showPluginFailure() {
        showFailure(
            message: NSLocalizedString(
                "插件分享失败。请在「文件」中选择插件并使用「用 Nox 打开」。",
                comment: "Share extension plugin import fallback"
            )
        )
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
