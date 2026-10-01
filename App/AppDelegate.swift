import UIKit
import UserNotifications
import NtfyKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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
        guard let payload = PushPayload(userInfo: userInfo) else { return .noData }
        let message = payload.message
        let center = UNUserNotificationCenter.current()
        let matching = await center.deliveredNotifications().filter {
            PushPayload(userInfo: $0.request.content.userInfo).map {
                $0.baseURL == payload.baseURL && $0.message.topic == message.topic && $0.message.effectiveSequenceID == message.effectiveSequenceID
            } ?? false
        }
        center.removeDeliveredNotifications(withIdentifiers: matching.map(\.request.identifier))
        if let subscription = model.store.subscription(baseURL: payload.baseURL, topic: message.topic) {
            model.store.apply([message], to: subscription)
            await model.publish()
        }
        return .newData
    }
}

/// UIKit calls these on an arbitrary queue and requires the completion handlers on the main thread, so
/// the work hops to the main actor and completes there. The async delegate variants would complete on the
/// cooperative pool instead, which UIKit rejects with an assertion.
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let threadIdentifier = notification.request.content.threadIdentifier
        nonisolated(unsafe) let completionHandler = completionHandler
        Task { @MainActor in
            completionHandler(self.model.router.selectedTopicKey == threadIdentifier ? [] : [.banner, .list, .sound])
            await self.model.refreshAll()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let payload = PushPayload(userInfo: request.content.userInfo)
        let actionIdentifier = response.actionIdentifier
        let requestIdentifier = request.identifier
        let threadIdentifier = request.content.threadIdentifier
        nonisolated(unsafe) let completionHandler = completionHandler
        Task { @MainActor in
            guard let payload else {
                completionHandler()
                return
            }
            await self.handle(payload, actionIdentifier: actionIdentifier, requestIdentifier: requestIdentifier, threadIdentifier: threadIdentifier, completion: completionHandler)
        }
    }

    /// Navigates first and completes before any network work, so a slow action cannot stall the tap.
    private func handle(_ payload: PushPayload, actionIdentifier: String, requestIdentifier: String, threadIdentifier: String, completion: () -> Void) async {
        let message = payload.message
        if actionIdentifier == NotificationCategories.markReadAction {
            await model.markRead(message, baseURL: payload.baseURL)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
            completion()
            return
        }
        if let action = message.actions?.first(where: { $0.id == actionIdentifier }) {
            completion()
            await ActionPerformer.perform(action)
            if action.clear == true {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
            }
            return
        }
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            model.router.show(topicKey: threadIdentifier)
        }
        completion()
        if actionIdentifier == UNNotificationDefaultActionIdentifier, let click = message.click, let url = URL(string: click) {
            await UIApplication.shared.open(url)
        }
    }
}
