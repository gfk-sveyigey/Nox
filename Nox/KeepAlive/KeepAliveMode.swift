import Foundation

/// 后台保活方式（设置项）。
///
/// 与下载解耦：只要有「排队中 / 下载中」的任务就启动，全部结束就停止。
enum KeepAliveMode: String, CaseIterable, Identifiable, Codable {
    case off
    case silentAudio
    case pictureInPicture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return L("关闭")
        case .silentAudio: return L("静音音频")
        case .pictureInPicture: return L("画中画 (PiP)")
        }
    }

    var detail: String {
        switch self {
        case .off:
            return L("不保活，切后台可能被系统挂起，下载会暂停。")
        case .silentAudio:
            return L("循环播放极短静音。可能打断其他 App 正在播放的音频。")
        case .pictureInPicture:
            return L("用系统画中画保活：不占用音频会话，不打断其他 App 的音频，也尽量减少与其他画中画的互相挤占。")
        }
    }
}
