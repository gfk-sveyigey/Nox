import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser

// MARK: - 行为

extension VideoBrowserView {
    // MARK: - 行为

    /// 让地址栏跟随 WebView 当前地址。
    ///
    /// 用户正在编辑地址时不覆盖（否则打字会被导航事件打断）。
    func syncAddress(with url: URL?) {
        guard !addressFocused, let url else { return }

        let text = url.absoluteString
        guard text != address else { return }
        address = text
    }

    func loadRequestedURLIfNeeded() {
        guard let url = requestedURL else { return }

        requestedURL = nil
        address = url.absoluteString
        parser.load(url)
        showingHome = false
    }

    func openAddress() {
        // 点击打开后收起键盘
        addressFocused = false

        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if !text.contains("://") {
            text = "https://" + text
        }

        guard let url = URL(string: text), url.scheme == "https" else {
            errorMessage = L("请输入 HTTPS 地址。")
            return
        }

        address = url.absoluteString
        parser.load(url)
        showingHome = false
    }

    func parse() async {
        guard parser.canParseCurrentPage, !isParsing else { return }

        addressFocused = false

        isParsing = true
        parseError = nil
        defer { isParsing = false }

        do {
            let video = try await parser.parseCurrentPage()
            parsedVideo = video

        } catch {
            parsedVideo = nil
            parseError = error.localizedDescription
        }
    }

    /// 「重新解析」：刷新资源列表，等待用户手动选择。
    func reparse() async {
        guard parser.canParseCurrentPage, !isParsing else { return }

        isParsing = true
        parseError = nil
        defer { isParsing = false }

        do {
            parsedVideo = try await parser.parseCurrentPage()
        } catch {
            parsedVideo = nil
            parseError = error.localizedDescription
        }
    }

    /// 「解析视频」路径。
    func download(_ variant: VideoVariant) async {
        guard let parsedVideo else { return }
        prepareDownload(title: parsedVideo.title, variant: variant, referer: parsedVideo.pageURL, parserName: parser.currentSiteName)
    }

    /// 嗅探面板路径。
    ///
    /// - Referer 用 WebView 当前地址。
    func download(_ item: SnifferBridge.Item) {
        showSniffer = false

        prepareDownload(
            title: item.displayTitle,
            variant: VideoVariant(
                quality: item.qualityLabel,
                format: item.format,
                url: item.url
            ),
            referer: parser.currentPageURL
        )
    }

    /// 统一的入队前准备：收起所有 sheet、取 Cookie、生成默认文件名、弹「选择文件名」。
    func prepareDownload(title: String, variant: VideoVariant, referer: URL?, parserName: String? = nil) {
        var metadata = variant.metadata ?? DownloadMetadata()
        metadata.originalPageURL = metadata.originalPageURL ?? referer ?? parser.currentPageURL
        metadata.parserName = metadata.parserName ?? parserName
        showParseSheet = false
        showSniffer = false

        Task {
            let cookieHeader = await parser.cookieHeaderForCurrentPage()

            let suggested = downloads.suggestedFilename(
                title: title,
                quality: variant.quality,
                format: variant.format
            )

            // 等 sheet 退场动画走完再弹 alert：动画期间同步 present 会被系统静默丢弃
            try? await Task.sleep(nanoseconds: 450_000_000)

            let suggestedURL = URL(fileURLWithPath: suggested)
            let fileExtension = suggestedURL.pathExtension

            // 输入框只放主名，扩展名单独固定，用户看不到也改不了
            filenameInput = suggestedURL.deletingPathExtension().lastPathComponent

            pendingRequest = DownloadRequest(
                title: title,
                variant: variant,
                referer: referer,
                cookieHeader: cookieHeader,
                metadata: metadata,
                fileExtension: fileExtension,
                defaultFilename: suggested
            )

            isFilenameDialogPresented = true
        }
    }

    func commit(_ request: DownloadRequest, useCustom: Bool) {
        var filename = request.defaultFilename

        if useCustom {
            // 用户只能改主名。就算他手动敲了后缀，也按固定扩展名收口 ——
            // 否则会出现「选了 .mp4 却存成 .mp4.txt」这类坏文件。
            let stem = Self.stem(
                from: filenameInput,
                stripping: request.fileExtension
            )

            if !stem.isEmpty {
                filename = "\(stem).\(request.fileExtension)"
            }
        }

        downloads.enqueue(
            title: request.title,
            variant: request.variant,
            referer: request.referer,
            cookieHeader: request.cookieHeader,
            filename: filename,
            metadata: request.metadata
        )

        isFilenameDialogPresented = false
    }

    /// 只剥掉「与固定扩展名完全一致」的尾缀。
    /// 不能按 `pathExtension` 通用剥离 —— 像 `S01.E02` 这种主名里的点会被误伤。
    static func stem(from text: String, stripping fileExtension: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileExtension.isEmpty else { return trimmed }

        let suffix = "." + fileExtension

        if trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            return String(trimmed.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }
}
