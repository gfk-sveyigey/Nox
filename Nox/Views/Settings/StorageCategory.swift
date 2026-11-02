import Foundation
import SwiftUI
import NoxCore
import NoxDownload

/// 「储存空间」里可单独统计与清理的类别。
///
/// 这里只保留用户能理解、且确实可能长期占用的项目。下载分片与暂存、
/// 网络缓存与系统临时文件分别合并，避免统计页出现一长串语义相近的行。
enum StorageCategory: String, CaseIterable, Identifiable {
    case videos
    case trash
    case downloadTemporary
    case caches
    case logs
    case websiteData
    case plugins
    case preferences
    case otherData

    var id: String { rawValue }

    /// 「可清理」分组，顺序即界面展示顺序。
    static let clearableCategories: [StorageCategory] = [
        .videos, .trash, .downloadTemporary, .caches, .logs, .websiteData
    ]

    /// 「不可清理」分组。插件、偏好设置与用户文件不参与批量删除。
    static let protectedCategories: [StorageCategory] = [
        .plugins, .preferences, .otherData
    ]

    var title: String {
        switch self {
        case .videos: return L("已下载视频")
        case .trash: return L("回收站")
        case .downloadTemporary: return L("下载临时文件")
        case .caches: return L("缓存")
        case .logs: return L("日志")
        case .websiteData: return L("网站数据")
        case .plugins: return L("插件")
        case .preferences: return L("偏好设置")
        case .otherData: return L("其他数据")
        }
    }

    var systemImage: String {
        switch self {
        case .videos: return "film"
        case .trash: return "trash"
        case .downloadTemporary: return "arrow.down.doc"
        case .caches: return "internaldrive"
        case .logs: return "doc.text"
        case .websiteData: return "globe"
        case .plugins: return "puzzlepiece.extension"
        case .preferences: return "gearshape"
        case .otherData: return "archivebox"
        }
    }

    /// 每一类使用独立颜色，行图标与占比条共用，方便一眼区分。
    var color: Color {
        switch self {
        case .videos:
            return Color(red: 0.24, green: 0.51, blue: 0.96)
        case .trash:
            return Color(red: 0.84, green: 0.28, blue: 0.34)
        case .downloadTemporary:
            return Color(red: 0.96, green: 0.52, blue: 0.18)
        case .caches:
            return Color(red: 0.84, green: 0.62, blue: 0.08)
        case .logs:
            return Color(red: 0.47, green: 0.51, blue: 0.57)
        case .websiteData:
            return Color(red: 0.18, green: 0.67, blue: 0.42)
        case .plugins:
            return Color(red: 0.59, green: 0.36, blue: 0.91)
        case .preferences:
            return Color(red: 0.31, green: 0.42, blue: 0.82)
        case .otherData:
            return Color(red: 0.66, green: 0.46, blue: 0.29)
        }
    }

    /// 只有用户预期可以清理的数据才参与多选，避免误删插件、偏好设置或用户文件。
    var canClear: Bool {
        switch self {
        case .videos, .trash, .downloadTemporary, .caches, .logs, .websiteData:
            return true
        case .plugins, .preferences, .otherData:
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
        let trash = manager.trashSize()
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
        let documentsOther = max(documents - videos - trash, 0)
        let otherData = documentsOther
            + applicationOther
            + applicationSupportOther
            + libraryOther
            + sharedContainer

        return [
            .videos: videos,
            .trash: trash,
            .downloadTemporary: parts + staging,
            .caches: caches + temporary,
            .logs: logs,
            .websiteData: websiteData,
            .plugins: plugins,
            .preferences: preferences,
            .otherData: otherData
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

        case .trash:
            return combined(DownloadStorage.trashDirectories.map { entries(in: $0) })

        case .downloadTemporary:
            return combined([
                entries(in: DownloadStorage.partsRoot),
                entries(in: DownloadStorage.stagingRoot)
            ])

        case .caches:
            return combined([
                entries(in: DownloadStorage.cachesDirectory),
                entries(in: DownloadStorage.temporaryDirectory)
            ])

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

        case .websiteData:
            return entries(in: DownloadStorage.webKitDirectory)

        case .plugins:
            return entries(in: DownloadStorage.pluginsDirectory)

        case .preferences:
            return entries(in: DownloadStorage.preferencesDirectory)

        case .otherData:
            let videoNames = Set(
                records
                    .filter { $0.status == .finished }
                    .compactMap { manager.shareableFileURL(for: $0)?.lastPathComponent }
            )
            let trashNames = Set(DownloadStorage.trashDirectories.map(\.lastPathComponent))
            var groups: [[StorageEntry]] = [
                entries(
                    in: DownloadStorage.documentsDirectory,
                    excluding: videoNames.union(trashNames)
                ),
                entries(
                    in: DownloadStorage.rootDirectory,
                    excluding: ["Parts", "Staging", "Plugins", "Nox.log"]
                ),
                entries(
                    in: DownloadStorage.applicationSupportDirectory,
                    excluding: ["Nox"]
                ),
                entries(
                    in: DownloadStorage.libraryDirectory,
                    excluding: ["Application Support", "Caches", "WebKit", "Preferences"]
                )
            ]
            if let directory = DownloadStorage.sharedContainerDirectory {
                groups.append(entries(in: directory))
            }
            return combined(groups)
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
            .sorted(by: entrySort)
    }

    private static func combined(_ groups: [[StorageEntry]]) -> [StorageEntry] {
        groups.flatMap { $0 }.sorted(by: entrySort)
    }

    private static func entrySort(_ lhs: StorageEntry, _ rhs: StorageEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
