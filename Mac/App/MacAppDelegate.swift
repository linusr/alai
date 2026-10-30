import AppKit
import UserNotifications

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var notifications = NotificationHandler(model: model)

    /// The delegate must be in place before launch finishes to receive the tap that launched the app.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notifications
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startSync()
        NSApplication.shared.registerForRemoteNotifications()
        // The live stream stays open while the app runs, in front or behind other apps
        model.setLiveUpdates(active: true)
        lastRefresh = .now
        Task {
            await model.refreshAll()
            await model.registerForPush()
        }
    }

    private var lastRefresh = Date.distantPast

    /// The open stream already delivers new messages, so switching back to the app polls at most once a minute.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard Date.now.timeIntervalSince(lastRefresh) > 60 else { return }
        lastRefresh = .now
        Task { await model.refreshAll() }
    }

    /// A single-window app quits with its window; APNs notifications still arrive while it is not running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.push.update(token: deviceToken)
        Task { await model.registerForPush() }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await model.applyBackgroundPush(userInfo) }
    }
}
