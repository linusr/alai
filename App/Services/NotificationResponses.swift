import Foundation
import UserNotifications
import NtfyKit

extension AppModel {
    /// Applies a background push, which carries a message_delete or message_clear event: removes the
    /// notifications it replaces and updates the stored message. Returns whether it was an Alai push.
    func applyBackgroundPush(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard let payload = PushPayload(userInfo: userInfo) else { return false }
        let message = payload.message
        let center = UNUserNotificationCenter.current()
        let matching = await center.deliveredNotifications().filter {
            PushPayload(userInfo: $0.request.content.userInfo).map {
                $0.baseURL == payload.baseURL && $0.message.topic == message.topic && $0.message.effectiveSequenceID == message.effectiveSequenceID
            } ?? false
        }
        center.removeDeliveredNotifications(withIdentifiers: matching.map(\.request.identifier))
        if let subscription = store.subscription(baseURL: payload.baseURL, topic: message.topic) {
            store.apply([message], to: subscription)
            await publish()
        }
        return true
    }

    /// Navigates first and completes before any network work, so a slow action cannot stall the tap.
    func handleNotificationResponse(_ payload: PushPayload, actionIdentifier: String, requestIdentifier: String, threadIdentifier: String, completion: () -> Void) async {
        let message = payload.message
        if actionIdentifier == NotificationCategories.markReadAction {
            await markRead(message, baseURL: payload.baseURL)
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
            router.show(topicKey: threadIdentifier)
        }
        completion()
        if actionIdentifier == UNNotificationDefaultActionIdentifier, let click = message.click, let url = URL(string: click) {
            await Platform.open(url)
        }
    }
}

/// Presents notifications in the foreground and handles taps and actions on them. The system calls these
/// on an arbitrary queue and requires the completion handlers on the main thread, so
/// the work hops to the main actor and completes there. The async delegate variants would complete on the
/// cooperative pool instead, which UIKit rejects with an assertion.
@MainActor
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

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
            await self.model.handleNotificationResponse(payload, actionIdentifier: actionIdentifier, requestIdentifier: requestIdentifier, threadIdentifier: threadIdentifier, completion: completionHandler)
        }
    }
}
