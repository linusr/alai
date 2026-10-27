import UIKit
import UserNotifications
import NtfyKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()
    private lazy var notifications = NotificationHandler(model: model)
    /// The SwiftUI adaptor owns this delegate; the scene delegate reaches the model through it.
    private(set) static var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            QuickActions.perform(item, model: model)
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notifications
        QuickActions.clearDynamic()
        model.startSync()
        BackgroundRefresh.register(model: model)
        BackgroundRefresh.schedule()
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.push.update(token: deviceToken)
        Task { await model.registerForPush() }
    }

    /// Background pushes carry message_delete and message_clear events.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await model.applyBackgroundPush(userInfo) ? .newData : .noData
    }
}
