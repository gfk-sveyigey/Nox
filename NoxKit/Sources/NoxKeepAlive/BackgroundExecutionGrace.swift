import Foundation
import UIKit
import NoxCore

/// 短时后台执行宽限。
///
/// `beginBackgroundTask` 不是长期保活手段，但能在 App 刚进入后台或收尾阶段
/// 争取一小段执行时间，避免 HLS 合并、MP4 导出和状态落盘被系统立刻挂起。
@MainActor
public final class BackgroundExecutionGrace {
    public static let shared = BackgroundExecutionGrace()

    private var tasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    private let startedAt = NSLock()
    private var starts: [UUID: Date] = [:]

    private init() {}

    /// 开始一段后台宽限。返回的 token 必须传给 `end`，或等待系统到期。
    @discardableResult
    public func begin(reason: String) -> UUID? {
        let token = UUID()
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Nox · \(reason)"
        ) { [weak self] in
            Task { @MainActor in
                self?.expire(token, reason: reason)
            }
        }

        guard identifier != .invalid else {
            LogStore.shared.warning("background grace unavailable · \(reason)")
            return nil
        }

        tasks[token] = identifier
        startedAt.lock()
        starts[token] = Date()
        startedAt.unlock()
        LogStore.shared.info("background grace begin · \(reason)")
        return token
    }

    /// 主动结束一段后台宽限。重复调用是安全的。
    public func end(_ token: UUID, reason: String = "") {
        guard let identifier = tasks.removeValue(forKey: token) else { return }
        startedAt.lock()
        let duration = starts[token].map { Date().timeIntervalSince($0) } ?? 0
        starts.removeValue(forKey: token)
        startedAt.unlock()
        UIApplication.shared.endBackgroundTask(identifier)
        LogStore.shared.info(
            String(format: "background grace end · %@ · %.1fs", reason, duration)
        )
    }

    private func expire(_ token: UUID, reason: String) {
        guard let identifier = tasks.removeValue(forKey: token) else { return }
        startedAt.lock()
        starts.removeValue(forKey: token)
        startedAt.unlock()
        // 到期回调必须调用 endBackgroundTask，否则系统会强杀进程。
        UIApplication.shared.endBackgroundTask(identifier)
        LogStore.shared.warning("background grace expired · \(reason)")
    }
}
