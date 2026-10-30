import AppKit
import UserNotifications
import OSLog

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var notifications = NotificationHandler(model: model)

    /// The delegate must be in place before launch finishes to receive the tap that launched the app.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notifications
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        applyScreenshotArguments()
        #endif
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

    #if DEBUG
    /// Store screenshot runs: `-appearance light|dark`, `-windowSize 1200x740` (points), which also brings the app
    /// to the front, and `-openSettings YES`.
    private func applyScreenshotArguments() {
        let defaults = UserDefaults.standard
        let log = Logger(subsystem: "me.4vr.alai", category: "DebugSeed")
        switch defaults.string(forKey: "appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case nil: break
        case let other?: log.error("Unknown -appearance \(other); use light or dark")
        }
        guard let value = defaults.string(forKey: "windowSize") else { return }
        let size = value.split(separator: "x").compactMap { Double($0) }
        guard size.count == 2 else { return log.error("Unreadable -windowSize \(value); use WIDTHxHEIGHT") }
        let wanted = NSSize(width: size[0], height: size[1])
        Task {
            // The SwiftUI window appears some time after launch finishes
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { continue }
                window.setContentSize(wanted)
                window.center()
                NSApp.activate()
                // AppKit keeps windows inside the visible screen, which can be smaller than the store sizes
                let actual = window.contentRect(forFrameRect: window.frame).size
                if actual != wanted {
                    log.error("Window is \(actual.debugDescription), not \(value): the screen is too small")
                }
                return
            }
            log.error("No main window to resize")
        }
    }
    #endif

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

    func applicationWillTerminate(_ notification: Notification) {
        model.cloud.flushReadThrough()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.push.update(token: deviceToken)
        Task { await model.registerForPush() }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await model.applyBackgroundPush(userInfo) }
    }
}
