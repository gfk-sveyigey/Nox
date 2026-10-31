
import Combine
import Foundation
import NoxCore

/// 下载引擎需要的最小状态面。
///
/// 由 App 层（`AppState`）实现，`NoxDownload` 因此不需要依赖具体状态类。
@MainActor
public protocol DownloadStateStore: AnyObject {
    var downloads: [DownloadRecord] { get set }
    /// 下载记录变化时发出（驱动后台保活的启停）。
    var downloadsPublisher: AnyPublisher<[DownloadRecord], Never> { get }

    var preferredQuality: PreferredQuality { get }
    var experimentalMultiThreadDownload: Bool { get }
    var multiThreadSegmentCount: Int { get }
    var m3u8SegmentConcurrency: Int { get }
    var maxConcurrentDownloads: Int { get }

    var keepAliveMode: KeepAliveMode { get set }
    var keepAliveLifetime: KeepAliveLifetime { get set }
    var pipCoexistenceFallback: PiPCoexistenceFallback { get set }
    var pipWindowHeight: Double { get set }
    var pipVerboseLogging: Bool { get set }

    func addDownload(_ record: DownloadRecord)
    func updateDownload(_ record: DownloadRecord, persist: Bool)
    func removeDownload(_ record: DownloadRecord)
    func clearFinishedDownloads()
    func addHistory(title: String, url: URL)
    func persist()
}

public extension DownloadStateStore {
    func updateDownload(_ record: DownloadRecord) {
        updateDownload(record, persist: true)
    }
}
