import Foundation

/// 后台保活方式（设置项）。
///
/// 与下载解耦：是否启动由「保活模式」（`KeepAliveLifetime`）决定 —— 跟随下载任务，或进入前台即常驻。
public enum KeepAliveMode: String, CaseIterable, Identifiable, Codable {
    /// 只在 App 前台下载；切到后台时暂停，回到前台后继续。
    case foregroundOnly
    /// 只依赖系统后台下载（Background URLSession），不额外保活。
    case off
    /// iOS 26 的 BGContinuedProcessingTask：用户前台发起后，系统继续给进程执行时间。
    case continuedProcessing
    case silentAudio
    case pictureInPicture

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return L("系统下载")
        case .foregroundOnly: return L("仅前台下载")
        case .continuedProcessing: return L("持续处理")
        case .silentAudio: return L("静音音频")
        case .pictureInPicture: return L("画中画 (PiP)")
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return L("普通文件和 HLS 都使用 Background URLSession；HLS 走可统计大小、速度并支持断点续传的分片引擎。")
        case .foregroundOnly:
            return L("不使用后台下载，也不启动保活。切到后台时暂停任务，回到前台后自动继续。")
        case .continuedProcessing:
            return L("App 在前台开始下载后，系统授予后台执行时间，并强制在其自带的锁屏 / 灵动岛面板显示进度与取消按钮；该面板无法替换为自定义实时活动。")
        case .silentAudio:
            return L("循环播放极低电平静音，让 App 保持运行；普通文件走后台会话，HLS 使用兼容分片引擎。锁屏后仍可继续，可能打断其他 App 正在播放的音频。")
        case .pictureInPicture:
            return L("用系统画中画让 App 保持运行；普通文件走后台会话，HLS 使用兼容分片引擎。锁屏后仍可继续，不占用音频会话，也尽量减少与其他画中画的互相挤占。")
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

    /// 这一档是否会启动额外的保活策略。
    public var startsKeepAlive: Bool {
        switch self {
        case .off, .foregroundOnly: return false
        default: return true
        }
    }

    /// 普通文件是否使用 Background URLSession。
    ///
    /// 除「仅前台下载」外都交给系统后台会话：URLSession 的 default 配置没有
    /// 独立的后台传输能力，App 一旦被系统挂起就会停。静音音频 / 画中画负责
    /// 尽量让 App 保持运行；普通文件的传输则始终交给后台会话。
    public var usesBackgroundDownloadSession: Bool {
        self != .foregroundOnly
    }

    /// HLS 分片是否使用后台 URLSession。
    ///
    /// 只有「系统下载」使用后台分片会话；静音音频 / 画中画 / 持续处理沿用
    /// 兼容分片引擎（URLSession.shared），由保活策略保证锁屏后的执行时间。
    public var usesBackgroundHLSSegments: Bool {
        self == .off
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
/// 要么暂缓启动画中画（绝不挤掉其他 App 正在播放的画中画），
/// 要么改用静音音频 / 干脆不保活。
public enum PiPCoexistenceFallback: String, CaseIterable, Identifiable, Codable {
    case keepAlive
    case silentAudio
    case stop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keepAlive: return L("暂缓启动画中画")
        case .silentAudio: return L("改用静音音频")
        case .stop: return L("停止保活")
        }
    }
}
