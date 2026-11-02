import Foundation
import UserNotifications
import NoxCore

/// 后台保活失效时的本地提醒。
///
/// 通知本身不参与保活，只用于避免用户误以为下载仍在后台继续。
public enum KeepAliveNotifier {
    public static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    public static func notifyInterrupted() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional ||
              settings.authorizationStatus == .ephemeral else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = L("后台下载已暂停")
        content.body = L("打开 Nox 可继续未完成的下载任务。")
        content.sound = .default
        content.threadIdentifier = "com.aholic.nox.keepalive"

        let request = UNNotificationRequest(
            identifier: "com.aholic.nox.keepalive.interrupted",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
