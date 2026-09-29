import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var history: [HistoryItem] = []
    @Published var downloads: [DownloadRecord] = []
    @Published var preferredQuality: PreferredQuality = .ask
    /// 实验性：多线程（分片）下载
    @Published var experimentalMultiThreadDownload = false
    /// 被用户关闭的站点标识（未列入即视为开启）
    @Published private var disabledSiteIDs: Set<String> = []

    private let historyKey = "VideoSaver.history"
    private let downloadsKey = "VideoSaver.downloads"
    private let qualityKey = "VideoSaver.quality"
    private let multiThreadKey = "VideoSaver.multiThreadDownload"
    private let disabledSitesKey = "VideoSaver.disabledSites"

    init() {
        load()
    }

    // MARK: - 历史

    func addHistory(title: String, url: URL) {
        history.removeAll { $0.url == url }
        history.insert(
            HistoryItem(id: UUID(), title: title, url: url, visitedAt: .now),
            at: 0
        )
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

    // MARK: - 下载

    func addDownload(_ record: DownloadRecord) {
        downloads.insert(record, at: 0)
        persist()
    }

    /// - Parameter persist: 高频进度回调传 false，避免每秒写 UserDefaults。
    func updateDownload(_ record: DownloadRecord, persist shouldPersist: Bool = true) {
        guard let index = downloads.firstIndex(where: { $0.id == record.id }) else {
            return
        }

        downloads[index] = record

        if shouldPersist {
            persist()
        }
    }

    func removeDownload(_ record: DownloadRecord) {
        downloads.removeAll { $0.id == record.id }
        persist()
    }

    func clearFinishedDownloads() {
        downloads.removeAll {
            $0.status == .finished ||
            $0.status == .failed ||
            $0.status == .cancelled
        }
        persist()
    }

    // MARK: - 站点开关

    func isSiteEnabled(_ identifier: String) -> Bool {
        !disabledSiteIDs.contains(identifier)
    }

    func setSite(_ identifier: String, enabled: Bool) {
        if enabled {
            disabledSiteIDs.remove(identifier)
        } else {
            disabledSiteIDs.insert(identifier)
        }
        persist()
    }

    // MARK: - 持久化

    func persist() {
        let defaults = UserDefaults.standard

        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }

        if let data = try? JSONEncoder().encode(downloads) {
            defaults.set(data, forKey: downloadsKey)
        }

        defaults.set(preferredQuality.rawValue, forKey: qualityKey)
        defaults.set(experimentalMultiThreadDownload, forKey: multiThreadKey)
        defaults.set(Array(disabledSiteIDs).sorted(), forKey: disabledSitesKey)
    }

    private func load() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: historyKey),
           let value = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = value
        }

        if let data = defaults.data(forKey: downloadsKey),
           let value = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            // 进程被系统回收时任务不会回调，残留的 .downloading 需要归位，
            // 否则会永远显示「下载中」且无法重试。
            downloads = value.map { record in
                guard record.status == .downloading else { return record }
                var updated = record
                updated.status = .cancelled
                updated.errorMessage = nil
                return updated
            }
        }

        preferredQuality = PreferredQuality.migrated(from: defaults.string(forKey: qualityKey))
        experimentalMultiThreadDownload = defaults.bool(forKey: multiThreadKey)
        disabledSiteIDs = Set(defaults.stringArray(forKey: disabledSitesKey) ?? [])
    }
}