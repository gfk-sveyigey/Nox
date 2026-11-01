import UIKit
import UniformTypeIdentifiers

/// 从系统分享面板接收网页链接，再交给 Nox 的浏览页打开。
///
/// Share Extension 没有官方的「打开宿主 App」能力，因此先尝试
/// `NSExtensionContext.open(_:)`；若系统拒绝，再走 responder chain 的兼容路径。
/// 两条路径都失败时，把链接复制到剪贴板并提示用户手动打开。
final class ShareViewController: UIViewController {
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

        loadSharedPageURL { [weak self] url in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let url else {
                    self.showFailure()
                    return
                }

                self.openHostApp(with: url)
            }
        }
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

        guard let extensionContext else {
            openUsingResponderChain(noxURL, fallbackURL: pageURL)
            return
        }

        extensionContext.open(noxURL) { [weak self] opened in
            DispatchQueue.main.async {
                guard let self else { return }

                if opened {
                    self.finish()
                } else {
                    self.openUsingResponderChain(noxURL, fallbackURL: pageURL)
                }
            }
        }
    }

    private func openUsingResponderChain(_ url: URL, fallbackURL: URL) {
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

        showFailure(copying: fallbackURL)
    }

    private func showFailure(copying pageURL: URL? = nil) {
        guard !hasFinished else { return }

        spinner.stopAnimating()
        statusLabel.isHidden = true

        if let pageURL {
            UIPasteboard.general.string = pageURL.absoluteString
        }

        let message = pageURL == nil
            ? NSLocalizedString("未能从分享内容中读取网页链接。", comment: "Share extension no URL")
            : NSLocalizedString(
                "链接已复制。请打开 Nox，在地址栏中粘贴并访问。",
                comment: "Share extension manual fallback"
            )

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
