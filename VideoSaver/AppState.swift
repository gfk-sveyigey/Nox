import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var history: [HistoryItem] = []
    @Published var downloads: [DownloadRecord] = []
    @Published var preferredQuality = "Ask Every Time"
    @Published var clearHistoryOnLaunch = false
    @Published private(set) var customDownloadFolderName: String?

    private let historyKey = "VideoSaver.history"
    private let downloadsKey = "VideoSaver.downloads"
    private let qualityKey = "VideoSaver.quality"
    private let clearHistoryKey = "VideoSaver.clearHistory"
    private let folderBookmarkKey = "VideoSaver.downloadFolderBookmark"
    private let folderNameKey = "VideoSaver.downloadFolderName"

    init() {
        load()
        if clearHistoryOnLaunch {
            history.removeAll()
            persist()
        }
    }

    func addHistory(title: String, url: URL) {
        history.removeAll { $0.url == url }
        history.insert(HistoryItem(id: UUID(), title: title, url: url, visitedAt: .now), at: 0)
        history = Array(history.prefix(50))
        persist()
    }

    func removeHistory(_ item: HistoryItem) {
        history.removeAll { $0.id == item.id }
        persist()
    }

    func clearHistory() {
        history.removeAll()
        persist()
    }

    func addDownload(_ record: DownloadRecord) {
        downloads.insert(record, at: 0)
        persist()
    }

    func updateDownload(_ record: DownloadRecord) {
        guard let index = downloads.firstIndex(where: { $0.id == record.id }) else { return }
        downloads[index] = record
        persist()
    }

    func removeDownload(_ record: DownloadRecord) {
        downloads.removeAll { $0.id == record.id }
        persist()
    }

    func clearFinishedDownloads() {
        downloads.removeAll { $0.status == .finished || $0.status == .failed || $0.status == .cancelled }
        persist()
    }

    func setDownloadFolder(bookmarkData: Data, displayName: String) {
        UserDefaults.standard.set(bookmarkData, forKey: folderBookmarkKey)
        UserDefaults.standard.set(displayName, forKey: folderNameKey)
        customDownloadFolderName = displayName
    }

    func clearDownloadFolder() {
        UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
        UserDefaults.standard.removeObject(forKey: folderNameKey)
        customDownloadFolderName = nil
    }

    func downloadFolderURL() -> URL {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale) else {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        if stale, let refreshed = try? url.bookmarkData(options: []) {
            UserDefaults.standard.set(refreshed, forKey: folderBookmarkKey)
        }
        return url
    }

    func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: historyKey) }
        if let data = try? JSONEncoder().encode(downloads) { defaults.set(data, forKey: downloadsKey) }
        defaults.set(preferredQuality, forKey: qualityKey)
        defaults.set(clearHistoryOnLaunch, forKey: clearHistoryKey)
    }

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: historyKey), let value = try? JSONDecoder().decode([HistoryItem].self, from: data) { history = value }
        if let data = defaults.data(forKey: downloadsKey), let value = try? JSONDecoder().decode([DownloadRecord].self, from: data) { downloads = value }
        preferredQuality = defaults.string(forKey: qualityKey) ?? "Ask Every Time"
        clearHistoryOnLaunch = defaults.bool(forKey: clearHistoryKey)
        customDownloadFolderName = defaults.string(forKey: folderNameKey)
    }
}
