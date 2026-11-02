import Foundation

/// 后台保活方式（设置项）。
///
/// 与下载解耦：是否启动由「保活模式」（`KeepAliveLifetime`）决定 —— 跟随下载任务，或进入前台即常驻。
public enum KeepAliveMode: String, CaseIterable, Identifiable, Codable {
    /// 只依赖系统后台下载（Background URLSession），不额外保活。
    case off
    /// iOS 26 的 BGContinuedProcessingTask：用户前台发起后，系统继续给进程执行时间。
    case continuedProcessing
    case silentAudio
    case pictureInPicture

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return L("仅系统下载")
        case .continuedProcessing: return L("持续处理 (iOS 26)")
        case .silentAudio: return L("静音音频")
        case .pictureInPicture: return L("画中画 (PiP)")
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return L("普通文件交给系统后台 URLSession 继续；HLS 分片编排、合并等必须让 App 进程执行的任务，切后台后可能暂停。")
        case .continuedProcessing:
            return L("iOS 26 起可用：用户在前台开始下载后，系统允许进程在后台继续处理，并显示进度与取消入口。")
        case .silentAudio:
            return L("循环播放极短静音。可能打断其他 App 正在播放的音频。")
        case .pictureInPicture:
            return L("用系统画中画保活：不占用音频会话，不打断其他 App 的音频，也尽量减少与其他画中画的互相挤占。")
        }
    }

    /// 当前系统是否支持这一档。
    public var isAvailable: Bool {
        switch self {
        case .continuedProcessing:
            if #available(iOS 26.0, *) { return true }
            return false
        default:
            return true
        }
    }
}

/// 保活模式：保活的生命周期跟谁绑定（设置项）。
public enum KeepAliveLifetime: String, CaseIterable, Identifiable, Codable {
    /// 只在有「排队中 / 下载中」任务时保活，全部结束就停止。
    case followTasks
    /// 只要保活方式不是「关闭」，进入前台就拉起并一直保持。
    case alwaysOn

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .followTasks: return L("跟随下载任务")
        case .alwaysOn: return L("启动即常驻")
        }
    }
}

/// 画中画「共存保护」不可用时的处理方式（用户在设置里选）。
///
/// 共存保护依赖系统内部接口；装不上时就只能做取舍：
/// 要么继续用画中画保活（可能把其他 App 的画中画挤掉），
/// 要么不打扰别人（改用静音音频 / 干脆不保活）。
public enum PiPCoexistenceFallback: String, CaseIterable, Identifiable, Codable {
    case keepAlive
    case silentAudio
    case stop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keepAlive: return L("继续用画中画")
        case .silentAudio: return L("改用静音音频")
        case .stop: return L("停止保活")
        }
    }
}
