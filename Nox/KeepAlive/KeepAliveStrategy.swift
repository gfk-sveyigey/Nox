import Foundation

enum KeepAliveError: Error, LocalizedError {
    /// 设备 / 系统不支持该保活方式。
    case unsupported(String)
    /// 设备本身支持，但当前时刻拿不到启动条件（例如没有前台窗口）。
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return String(format: L("%@ 在当前设备上不可用"), name)
        case .unavailable(let name):
            return String(format: L("%@ 暂时无法启动"), name)
        }
    }
}

/// 保活策略：静音音频 / 画中画两种实现的统一抽象。
@MainActor
protocol KeepAliveStrategy: AnyObject {
    var name: String { get }
    var isActive: Bool { get }
    /// 被系统打断（来电、其它 App 抢占音频、用户关闭 PiP）时回调。
    var onInterruption: (() -> Void)? { get set }

    func start() throws
    func stop()
}
