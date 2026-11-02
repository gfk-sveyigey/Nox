import Foundation

/// 保存系统交给 App 的后台 URLSession 完成回调。
///
/// `URLSession` 在后台事件处理完后会调用
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`，
/// App 必须先保存这个 handler，等对应 session 的
/// `urlSessionDidFinishEvents(forBackgroundURLSession:)` 回调再调用。
/// 漏掉这一步会让系统误以为 App 还没处理完，影响后续后台唤醒。
public final class BackgroundSessionEvents {
    public static let shared = BackgroundSessionEvents()

    private let lock = NSLock()
    private var handlers: [String: () -> Void] = [:]

    private init() {}

    public func store(identifier: String, handler: @escaping () -> Void) {
        lock.lock()
        let previous = handlers.updateValue(handler, forKey: identifier)
        lock.unlock()
        previous?()
    }

    public func hasPending(identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return handlers[identifier] != nil
    }

    public func complete(identifier: String) {
        lock.lock()
        let handler = handlers.removeValue(forKey: identifier)
        lock.unlock()
        handler?()
    }
}
