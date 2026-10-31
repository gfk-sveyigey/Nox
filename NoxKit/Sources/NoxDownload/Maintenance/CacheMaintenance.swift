import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - 缓存统计与清理

extension DownloadManager {
    // MARK: - 缓存（未完成的分片与暂存文件）

    /// 缓存占用：`Parts` 与 `Staging` 两个目录的字节数。
    ///
    /// 不含 `Documents`（已下载的视频），也不含 WKWebView 的网站数据
    /// —— 后者含登录态，清掉会把用户退出登录。
    public func cacheSize() -> Int64 {
        partsSize() + stagingSize()
    }

    /// 未完成下载的分片占用
    public func partsSize() -> Int64 {
        Self.directorySize(DownloadStorage.partsRoot)
    }

    /// 暂存（分片合并前的落盘中转）占用
    public func stagingSize() -> Int64 {
        Self.directorySize(DownloadStorage.stagingRoot)
    }

    /// 网络缓存占用。
    ///
    /// 原先读 `URLCache.shared`，但本 App 的探测请求用 `.reloadIgnoringLocalCacheData`、
    /// 下载走独立的 background session、WebView 又用自己的缓存 —— 于是它永远显示 0，
    /// 和「网络缓存」这个名字对不上。改为按沙盒的 `Library/Caches` 目录统计。
    public func networkCacheSize() -> Int64 {
        Self.directorySize(DownloadStorage.cachesDirectory)
    }

    /// 网站数据占用（Cookie、本地存储、网页缓存），按 WebKit 数据目录估算。
    public func websiteDataSize() -> Int64 {
        Self.directorySize(DownloadStorage.webKitDirectory)
    }

    /// 已下载视频占用的空间。
    ///
    /// 只统计「记录仍在且文件确实存在」的成品，而不是整个 `Documents` 目录 ——
    /// 后者会把用户自己通过「文件」App 放进来的东西一起算上，数值对不上。
    public func videosSize() -> Int64 {
        store.downloads.reduce(into: Int64(0)) { total, record in
            guard record.status == .finished, let url = shareableFileURL(for: record) else { return }
            total += DownloadStorage.fileSize(at: url)
        }
    }

    /// App 回到前台时调用：丢弃后台期间的速度采样，并把列表里的速度清零。
    ///
    /// 后台时进度定时器不会触发。恢复后的第一帧无论是沿用旧基准点（把跨越整个后台的
    /// 时间差当分母），还是把后台累积的字节塞进 1 秒里，都会得到明显偏离真实值的数字；
    /// 直接把估算器重置，等新的采样窗口建立即可。
    func resetSpeedSamples() {
        for id in Array(speedMeters.keys) {
            speedMeters[id]?.reset()

            if var stats = transfers[id] {
                stats.bytesPerSecond = 0
                transfers[id] = stats
            }
        }
    }

    /// 场景切换：回前台重算速度采样，并让保活自愈（例如 PiP 被系统结束后重建）。
    public func handleScenePhase(isActive: Bool) {
        guard isActive else { return }
        resetSpeedSamples()
        keepAlive.didEnterForeground()
    }

    /// 清空缓存：删除未完成下载的分片与暂存文件，以及 HTTP 网络缓存。
    ///
    /// 已完成的视频在 `Documents`，不受影响（其分片目录在完成时就已经清理）。
    public func clearCache() {
        clearParts()
        clearStaging()
        clearNetworkCache()
    }

    /// 清理未完成下载的分片。
    ///
    /// 正在下载 / 排队中的任务会被跳过，否则会把它们正在写的文件删掉。
    public func clearParts() {
        Self.removeSubdirectories(
            in: DownloadStorage.partsRoot,
            keeping: activeIDs.union(pendingQueue)
        )
    }

    /// 清理暂存文件（同样跳过正在下载 / 排队中的任务）
    public func clearStaging() {
        Self.removeSubdirectories(
            in: DownloadStorage.stagingRoot,
            keeping: activeIDs.union(pendingQueue)
        )
    }

    /// 清理网络缓存：内存中的 URLCache + 沙盒 `Library/Caches` 目录。
    public func clearNetworkCache() {
        URLCache.shared.removeAllCachedResponses()
        Self.removeContents(of: DownloadStorage.cachesDirectory)
    }

    /// 清理网站数据（Cookie / 本地存储 / 网页缓存）。
    ///
    /// - Warning: 会一并清掉登录态，用户需要重新登录相关网站。
    public func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }

    static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return 0
        }

        var total: Int64 = 0

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])

            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }

        return total
    }

    /// 删除目录下的所有内容（保留目录本身）
    static func removeContents(of directory: URL) {
        let fileManager = FileManager.default

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for entry in entries {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// 删除目录下的一级子目录，`keep` 中的 UUID 目录除外。
    /// 散落的非目录条目（临时文件）一并删除。
    static func removeSubdirectories(in directory: URL, keeping keep: Set<UUID>) {
        let fileManager = FileManager.default

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            guard isDirectory, let id = UUID(uuidString: entry.lastPathComponent) else {
                try? fileManager.removeItem(at: entry)
                continue
            }

            guard !keep.contains(id) else { continue }

            try? fileManager.removeItem(at: entry)
        }
    }
}
