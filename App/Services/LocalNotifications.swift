import Foundation
import UserNotifications
import NtfyKit

/// Notifications for messages found by polling, formatted like pushed ones.
enum LocalNotifications {
    static func post(_ message: Message, baseURL: URL) async {
        let content = UNMutableNotificationContent()
        NotificationFormatter.apply(message, baseURL: baseURL, to: content)
        content.categoryIdentifier = await NotificationCategories.register(for: message)
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
