import Foundation
import NoxCore
import NoxDownload

/// 「储存空间」里可单独统计与清理的类别。
enum StorageCategory: String, CaseIterable, Identifiable {
    case videos
    case documentsOther
    case parts
    case staging
    case plugins
    case logs
    case applicationOther
    case applicationSupportOther
    case networkCache
    case websiteData
    case preferences
    case libraryOther
    case temporary
    case sharedContainer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: return L("已下载视频")
        case .documentsOther: return L("其他文件")
        case .parts: return L("下载分片")
        case .staging: return L("临时文件")
        case .plugins: return L("插件")
        case .logs: return L("日志")
        case .applicationOther: return L("其他应用数据")
        case .applicationSupportOther: return L("其他支持文件")
        case .networkCache: return L("网络缓存")
        case .websiteData: return L("网站数据")
        case .preferences: return L("偏好设置")
        case .libraryOther: return L("其他资料库数据")
        case .temporary: return L("系统临时文件")
        case .sharedContainer: return L("共享数据")
        }
    }

    var systemImage: String {
        switch self {
        case .videos: return "film"
        case .documentsOther: return "doc"
        case .parts: return "square.split.2x2"
        case .staging: return "folder"
        case .plugins: return "puzzlepiece.extension"
        case .logs: return "doc.text"
        case .applicationOther: return "archivebox"
        case .applicationSupportOther: return "externaldrive"
        case .networkCache: return "network"
        case .websiteData: return "globe"
        case .preferences: return "gearshape"
        case .libraryOther: return "books.vertical"
        case .temporary: return "clock.arrow.circlepath"
        case .sharedContainer: return "square.stack.3d.up"
        }
    }

    /// 只有用户预期可以清理的数据才参与多选，避免误删插件、偏好设置或待导入文件。
    var canClear: Bool {
        switch self {
        case .videos, .parts, .staging, .logs, .networkCache, .websiteData, .temporary:
            return true
        case .documentsOther, .plugins, .applicationOther, .applicationSupportOther,
             .preferences, .libraryOther, .sharedContainer:
            return false
        }
    }
}

/// 储存详情里的一个文件或文件夹。
struct StorageEntry: Identifiable {
    let url: URL
    let isDirectory: Bool
    let bytes: Int64

    var id: String { url.path }
    var name: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}

/// 储存空间统计与目录展开。
///
/// 统计范围覆盖 App 沙盒内所有可写目录，以及分享扩展使用的 App Group 容器：
/// Documents、Application Support、Caches、WebKit、Preferences、Library 其余部分、
/// 系统临时目录。只读的 App 本体不计入。
@MainActor
enum StorageUsage {
    static func snapshot(manager: DownloadManager) -> [StorageCategory: Int64] {
        let videos = manager.videosSize()
        let parts = manager.partsSize()
        let staging = manager.stagingSize()
        let plugins = DeviceStorage.directorySize(at: DownloadStorage.pluginsDirectory)
        let logs = DownloadStorage.fileSize(at: DownloadStorage.logFileURL)
        let caches = manager.networkCacheSize()
        let websiteData = manager.websiteDataSize()
        let temporary = manager.temporarySize()
        let preferences = DeviceStorage.directorySize(at: DownloadStorage.preferencesDirectory)

        let documents = DeviceStorage.directorySize(at: DownloadStorage.documentsDirectory)

        let applicationSupport = DeviceStorage.directorySize(
            at: DownloadStorage.applicationSupportDirectory
        )
        let noxApplicationSupport = DeviceStorage.directorySize(at: DownloadStorage.rootDirectory)
        let library = DeviceStorage.directorySize(at: DownloadStorage.libraryDirectory)
        let sharedContainer = DownloadStorage.sharedContainerDirectory
            .map { DeviceStorage.directorySize(at: $0) } ?? 0

        let applicationOther = max(noxApplicationSupport - parts - staging - plugins - logs, 0)
        let applicationSupportOther = max(applicationSupport - noxApplicationSupport, 0)
        let libraryOther = max(
            library - applicationSupport - caches - websiteData - preferences,
            0
        )

        return [
            .videos: videos,
            .documentsOther: max(documents - videos, 0),
            .parts: parts,
            .staging: staging,
            .plugins: plugins,
            .logs: logs,
            .applicationOther: applicationOther,
            .applicationSupportOther: applicationSupportOther,
            .networkCache: caches,
            .websiteData: websiteData,
            .preferences: preferences,
            .libraryOther: libraryOther,
            .temporary: temporary,
            .sharedContainer: sharedContainer
        ]
    }

    static func total(_ sizes: [StorageCategory: Int64]) -> Int64 {
        sizes.values.reduce(0, +)
    }

    static func children(
        for category: StorageCategory,
        manager: DownloadManager,
        records: [DownloadRecord]
    ) -> [StorageEntry] {
        switch category {
        case .videos:
            var seen = Set<String>()
            return records
                .filter { $0.status == .finished }
                .compactMap { record -> StorageEntry? in
                    guard let url = manager.shareableFileURL(for: record) else { return nil }
                    guard seen.insert(url.path).inserted else { return nil }
                    return StorageEntry(
                        url: url,
                        isDirectory: false,
                        bytes: DownloadStorage.fileSize(at: url)
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        case .documentsOther:
            let videoNames = Set(
                records
                    .filter { $0.status == .finished }
                    .compactMap { manager.shareableFileURL(for: $0)?.lastPathComponent }
            )
            return entries(in: DownloadStorage.documentsDirectory, excluding: videoNames)

        case .parts:
            return entries(in: DownloadStorage.partsRoot)

        case .staging:
            return entries(in: DownloadStorage.stagingRoot)

        case .plugins:
            return entries(in: DownloadStorage.pluginsDirectory)

        case .logs:
            let url = DownloadStorage.logFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return [
                StorageEntry(
                    url: url,
                    isDirectory: false,
                    bytes: DownloadStorage.fileSize(at: url)
                )
            ]

        case .applicationOther:
            return entries(
                in: DownloadStorage.rootDirectory,
                excluding: ["Parts", "Staging", "Plugins", "Nox.log"]
            )

        case .applicationSupportOther:
            return entries(
                in: DownloadStorage.applicationSupportDirectory,
                excluding: ["Nox"]
            )

        case .networkCache:
            return entries(in: DownloadStorage.cachesDirectory)

        case .websiteData:
            return entries(in: DownloadStorage.webKitDirectory)

        case .preferences:
            return entries(in: DownloadStorage.preferencesDirectory)

        case .libraryOther:
            return entries(
                in: DownloadStorage.libraryDirectory,
                excluding: ["Application Support", "Caches", "WebKit", "Preferences"]
            )

        case .temporary:
            return entries(in: DownloadStorage.temporaryDirectory)

        case .sharedContainer:
            guard let directory = DownloadStorage.sharedContainerDirectory else { return [] }
            return entries(in: directory)
        }
    }

    static func entries(
        in directory: URL,
        excluding excludedNames: Set<String> = []
    ) -> [StorageEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        )) ?? []

        return urls
            .filter { !excludedNames.contains($0.lastPathComponent) }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = values?.isDirectory ?? false
                let bytes = isDirectory
                    ? DeviceStorage.directorySize(at: url)
                    : Int64(values?.fileSize ?? 0)
                return StorageEntry(url: url, isDirectory: isDirectory, bytes: bytes)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
