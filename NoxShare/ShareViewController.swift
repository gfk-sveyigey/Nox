import UIKit
import UniformTypeIdentifiers

/// 从系统分享面板接收网页链接或插件文件。
///
/// 插件文件会先写入 App Group 共享目录，再让用户选择「导入并打开」或
/// 「仅导入」——即使系统拒绝 Share Extension 唤起宿主 App（Apple 文档：
/// iOS 只有 Today / iMessage 扩展支持 `NSExtensionContext.open`），
/// 数据也已经保存，打开 Nox 时仍会自动导入。
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
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private var hasStarted = false
    private var hasFinished = false
    private var sharedFileName: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        spinner.startAnimating()

        statusLabel.text = NSLocalizedString("正在打开 Nox…", comment: "Share extension opening status")
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        // 分享面板的高度由系统决定，可能是半屏也可能被用户拖得更矮。
        // 用滚动视图 + 居中的内容栈，按钮多时仍能完整显示。
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentStack)

        contentStack.addArrangedSubview(spinner)
        contentStack.addArrangedSubview(statusLabel)

        // 内容少时与分享面板等高；内容多时由下面的约束撑高并允许滚动。
        let fitHeight = contentView.heightAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.heightAnchor
        )
        fitHeight.priority = .defaultLow

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentView.heightAnchor.constraint(
                greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor
            ),
            fitHeight,

            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            contentStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentStack.topAnchor.constraint(
                greaterThanOrEqualTo: contentView.topAnchor,
                constant: 20
            ),
            contentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor,
                constant: -20
            )
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !hasStarted else { return }
        hasStarted = true

        // 读取附件 / 打开宿主 App 都可能卡住。加一个总超时，避免扩展一直
        // 停在「正在打开 Nox…」，让用户至少能看到失败提示。
        var didResolve = false
        func resolve(_ payload: SharedPayload?) {
            guard !didResolve else { return }
            didResolve = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let payload else {
                    NSLog("NoxShare: payload timeout or unreadable")
                    self.showFailure()
                    return
                }

                switch payload {
                case .web(let url):
                    self.openHostApp(with: url)
                case .plugin(let data):
                    self.presentPluginOptions(for: data)
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

        loadSharedPayload { payload in
            resolve(payload)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            resolve(nil)
        }
    }

    private func loadSharedPayload(completion: @escaping (SharedPayload?) -> Void) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        NSLog(
            "NoxShare: %ld attachment(s) %@",
            providers.count,
            providers.map(\.registeredTypeIdentifiers).description
        )
        sharedFileName = providers.compactMap(\.suggestedName).first

        loadPluginData(from: providers) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }

                if let data {
                    NSLog("NoxShare: plugin payload %ld bytes", data.count)
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
                loadFileRepresentationData(from: provider) { data in
                    if let data {
                        completion(data)
                    } else {
                        loadProvider()
                    }
                }
                return
            }

            var typeIndex = 0
            func loadType() {
                guard typeIndex < types.count else {
                    // 有的文件提供方只实现了 loadFileRepresentation，
                    // loadItem 永远拿不到可用对象，这里再兜一次。
                    loadFileRepresentationData(from: provider) { data in
                        if let data {
                            completion(data)
                        } else {
                            loadProvider()
                        }
                    }
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

    /// 一些文件提供方（iCloud Drive、第三方网盘）只通过
    /// `loadFileRepresentation` 提供实际文件内容。
    private func loadFileRepresentationData(
        from provider: NSItemProvider,
        completion: @escaping (Data?) -> Void
    ) {
        guard
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasItemConformingToTypeIdentifier(Self.pluginTypeIdentifier)
        else {
            completion(nil)
            return
        }

        let typeIdentifier = provider.hasItemConformingToTypeIdentifier(Self.pluginTypeIdentifier)
            ? Self.pluginTypeIdentifier
            : UTType.data.identifier

        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            if let error {
                NSLog(
                    "NoxShare: loadFileRepresentation failed: %@",
                    error.localizedDescription
                )
            }
            guard let self, let url, let data = self.fileData(at: url) else {
                completion(nil)
                return
            }
            // 临时副本不一定保留原文件名，用插件头再确认一次，避免把
            // 普通文件当成插件交给宿主 App。
            guard self.isPluginName(url.lastPathComponent) || self.isPluginData(data) else {
                completion(nil)
                return
            }
            completion(data)
        }
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

        // iCloud Drive / 第三方文件提供方可能只给了占位文件，先请求下载。
        let status = try? url.resourceValues(
            forKeys: [.ubiquitousItemDownloadingStatusKey]
        ).ubiquitousItemDownloadingStatus
        if status != nil, status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            for _ in 0..<20 {
                let current = try? url.resourceValues(
                    forKeys: [.ubiquitousItemDownloadingStatusKey]
                ).ubiquitousItemDownloadingStatus
                if current == .current { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        var coordinationError: NSError?
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            data = try? Data(contentsOf: $0)
        }
        if let coordinationError {
            NSLog(
                "NoxShare: read %@ failed: %@",
                url.lastPathComponent,
                coordinationError.localizedDescription
            )
        }
        return data
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

    // MARK: - 插件导入选项

    private func presentPluginOptions(for data: Data) {
        spinner.stopAnimating()
        spinner.isHidden = true

        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.text = pluginSummary(for: data)

        let openButton = makeActionButton(
            title: NSLocalizedString("导入并打开", comment: "Share extension import and open"),
            subtitle: NSLocalizedString("保存后立即打开 Nox", comment: "Share extension import and open subtitle"),
            prominent: true
        )
        let saveButton = makeActionButton(
            title: NSLocalizedString("仅导入", comment: "Share extension import only"),
            subtitle: NSLocalizedString("打开 Nox 时自动导入", comment: "Share extension import only subtitle"),
            prominent: false
        )
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle(
            NSLocalizedString("取消", comment: "Share extension cancel import"),
            for: .normal
        )
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)

        contentStack.addArrangedSubview(openButton)
        contentStack.addArrangedSubview(saveButton)
        contentStack.addArrangedSubview(cancelButton)

        openButton.addAction(UIAction { [weak self] _ in
            self?.importPlugin(data, openApp: true)
        }, for: .touchUpInside)
        saveButton.addAction(UIAction { [weak self] _ in
            self?.importPlugin(data, openApp: false)
        }, for: .touchUpInside)
        cancelButton.addAction(UIAction { [weak self] _ in
            self?.finish()
        }, for: .touchUpInside)
    }

    private func makeActionButton(
        title: String,
        subtitle: String,
        prominent: Bool
    ) -> UIButton {
        var configuration = prominent
            ? UIButton.Configuration.filled()
            : UIButton.Configuration.gray()
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.titleAlignment = .center
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 20, bottom: 14, trailing: 20
        )
        if prominent {
            configuration.baseBackgroundColor = .systemBlue
            configuration.baseForegroundColor = .white
        }

        let button = UIButton(configuration: configuration)
        button.titleLabel?.numberOfLines = 2
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return button
    }

    private func pluginSummary(for data: Data) -> String {
        let name = sharedFileName ?? "plugin.noxplugin"
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        return "\(name)\n\(size) · \(NSLocalizedString("Nox 插件", comment: "Share extension plugin kind"))"
    }

    private func importPlugin(_ data: Data, openApp: Bool) {
        contentStack.isUserInteractionEnabled = false

        if let stored = SharedPluginInbox.store(data) {
            NSLog(
                "NoxShare: plugin saved to shared inbox %@ (%ld bytes)",
                stored.lastPathComponent,
                data.count
            )
            if openApp {
                openPluginImportURL { [weak self] in
                    self?.showSavedMessage()
                }
            } else {
                showSavedMessage()
            }
            return
        }

        NSLog("NoxShare: shared inbox unavailable")
        guard openApp else {
            showFailure(
                title: NSLocalizedString("无法仅导入", comment: "Share extension import only unavailable title"),
                message: NSLocalizedString(
                    "当前安装不支持共享存储，请使用「导入并打开」。",
                    comment: "Share extension import only unavailable message"
                )
            )
            return
        }

        openHostAppForPluginViaURL(data)
    }

    private func openPluginImportURL(onFailure: @escaping () -> Void) {
        guard let url = URL(string: "nox://import-plugin") else {
            onFailure()
            return
        }
        openNoxURL(url, onFailure: onFailure)
    }

    private func openHostAppForPluginViaURL(_ data: Data) {
        // 没有 App Group 时退回旧方案：压缩后塞进 URL。
        // 自定义 URL 太长会被系统拒绝打开。
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
            NSLog("NoxShare: import url too long")
            showPluginFailure()
            return
        }

        NSLog(
            "NoxShare: import url %d bytes (compressed=%@)",
            noxURL.absoluteString.utf8.count,
            compressed ? "yes" : "no"
        )

        openNoxURL(noxURL) { [weak self] in
            self?.showPluginFailure()
        }
    }

    private func showPluginFailure() {
        showFailure(
            message: NSLocalizedString(
                "插件分享失败。请打开 Nox，在「设置 → 解析来源」中手动导入。",
                comment: "Share extension plugin import fallback"
            )
        )
    }

    private func showSavedMessage() {
        showFailure(
            title: NSLocalizedString("已保存到 Nox", comment: "Share extension saved title"),
            message: NSLocalizedString(
                "插件已保存。打开 Nox 后会自动导入。",
                comment: "Share extension saved message"
            )
        )
    }

    private func openNoxURL(_ url: URL, onFailure: @escaping () -> Void) {
        NSLog("NoxShare: opening host app via %@", url.host ?? "?")

        guard let extensionContext else {
            openUsingResponderChain(url, onFailure: onFailure)
            return
        }

        var resolved = false
        func resolve(opened: Bool) {
            guard !resolved else { return }
            resolved = true

            if opened {
                NSLog("NoxShare: extensionContext.open succeeded")
                // 不要立刻 completeRequest：个别系统版本会抢在宿主 App
                // 真正收到 URL 之前收掉扩展进程。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.finish()
                }
            } else {
                NSLog("NoxShare: extensionContext.open failed, trying responder chain")
                openUsingResponderChain(url, onFailure: onFailure)
            }
        }

        extensionContext.open(url) { opened in
            DispatchQueue.main.async {
                resolve(opened: opened)
            }
        }

        // 少数系统版本上 open 的 completion 可能永远不回调，超时后改走
        // responder chain，避免扩展一直停在转圈界面。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard !resolved else { return }
            resolved = true
            NSLog("NoxShare: extensionContext.open timed out, trying responder chain")
            self.openUsingResponderChain(url, onFailure: onFailure)
        }
    }

    private func openUsingResponderChain(_ url: URL, onFailure: @escaping () -> Void) {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector) {
                NSLog(
                    "NoxShare: %@ handled openURL",
                    String(describing: type(of: current))
                )
                _ = current.perform(selector, with: url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.finish()
                }
                return
            }
            responder = current.next
        }

        NSLog("NoxShare: no responder handled openURL")
        onFailure()
    }

    private func showFailure(
        title: String? = nil,
        message: String? = nil,
        copying pageURL: URL? = nil
    ) {
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
            title: title ?? NSLocalizedString("无法打开 Nox", comment: "Share extension failure title"),
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
