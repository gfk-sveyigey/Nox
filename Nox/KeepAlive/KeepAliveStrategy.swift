import Foundation

enum KeepAliveError: Error, LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return String(format: L("%@ 在当前设备上不可用"), name)
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
