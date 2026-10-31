import Foundation
import NoxCore

enum KeepAliveError: Error, LocalizedError {
    /// 设备 / 系统不支持该保活方式。
    case unsupported(String)
    /// 设备本身支持，但当前时刻拿不到启动条件（例如没有前台窗口）。
    case unavailable(String)
    /// 画中画能启动，但共存保护装不上（系统内部接口不可用）。
    case coexistenceUnavailable(String)

    /// 是否是「共存保护不可用」——协调器据此走用户选定的兜底方案。
    var isCoexistenceUnavailable: Bool {
        if case .coexistenceUnavailable = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return String(format: L("%@ 在当前设备上不可用"), name)
        case .unavailable(let name):
            return String(format: L("%@ 暂时无法启动"), name)
        case .coexistenceUnavailable(let name):
            return String(format: L("%@ 的共存保护不可用"), name)
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
