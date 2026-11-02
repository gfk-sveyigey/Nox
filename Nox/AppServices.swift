import Foundation
import NoxDownload
import NoxState

/// App 级长生命周期对象。
///
/// 前台 SwiftUI 界面和 BGTask 后台恢复必须复用同一份状态与下载管理器，
/// 否则后台任务创建的实例无法和前台界面同步，还可能与后台 URLSession 抢回调。
@MainActor
final class AppServices {
    static let shared = AppServices()

    let appState: AppState
    let downloadManager: DownloadManager
    let liveActivity: DownloadLiveActivityManager

    private init() {
        let state = AppState()
        let manager = DownloadManager(store: state)
        appState = state
        downloadManager = manager
        liveActivity = DownloadLiveActivityManager(
            appState: state,
            downloadManager: manager
        )
    }
}
