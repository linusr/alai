import AppKit
import UserNotifications

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var notifications = NotificationHandler(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notifications
        model.startSync()
        NSApplication.shared.registerForRemoteNotifications()
        // A Mac app stays running with its window closed, so it keeps the live stream open throughout
        model.setLiveUpdates(active: true)
        Task {
            await model.refreshAll()
            await model.registerForPush()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.refreshAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.push.update(token: deviceToken)
        Task { await model.registerForPush() }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await model.applyBackgroundPush(userInfo) }
    }
}
