import Foundation
import UserNotifications

/// Turns an ntfy message into notification content. Shared by the notification service extension
/// (remote pushes) and the app (messages delivered while it polls).
public enum NotificationFormatter {
    public static func apply(_ message: Message, baseURL: URL, to content: UNMutableNotificationContent) {
        let emoji = message.emojiTags.joined()
        let title = message.title.flatMap { $0.isEmpty ? nil : $0 }
        let heading = title ?? message.topic
        content.title = emoji.isEmpty ? heading : "\(emoji) \(heading)"
        content.subtitle = title == nil ? "" : message.topic
        content.body = bodyText(message)
        content.threadIdentifier = topicKey(baseURL: baseURL, topic: message.topic)
        content.targetContentIdentifier = content.threadIdentifier

        let priority = message.effectivePriority
        content.interruptionLevel = interruptionLevel(priority)
        content.relevanceScore = Double(priority.rawValue) / Double(Priority.max.rawValue)
        content.sound = priority <= .low ? nil : .default

        var userInfo = content.userInfo
        PushPayload(baseURL: baseURL, message: message).userInfo.forEach { userInfo[$0] = $1 }
        content.userInfo = userInfo
    }

    public static func bodyText(_ message: Message) -> String {
        if message.encoding == "base64" { return "Binary message" }
        let text = message.message ?? ""
        if text.isEmpty, let attachment = message.attachment { return "📎 \(attachment.name)" }
        guard message.isMarkdown,
              let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return text }
        return String(attributed.characters)
    }

    public static func interruptionLevel(_ priority: Priority) -> UNNotificationInterruptionLevel {
        switch priority {
        case .min, .low: .passive
        case .default: .active
        case .high, .max: .timeSensitive
        }
    }
}

/// Notification categories. Every notification offers Mark as Read; iOS only shows buttons of registered
/// categories, so each message with its own actions gets a category, pruned once its notification is gone.
public enum NotificationCategories {
    public static let prefix = "ntfy.actions."
    /// Category of messages without their own actions.
    public static let plain = "alai.message"
    public static let markReadAction = "alai.markRead"

    /// Registers the message's category and returns its identifier.
    public static func register(for message: Message) async -> String {
        let actions = Array((message.actions ?? []).compactMap(notificationAction).prefix(3))
        let identifier = actions.isEmpty ? plain : prefix + message.id
        let center = UNUserNotificationCenter.current()
        let delivered = Set(await center.deliveredNotifications().map(\.request.content.categoryIdentifier))
        var categories = await center.notificationCategories().filter {
            !$0.identifier.hasPrefix(prefix) || delivered.contains($0.identifier)
        }
        categories.insert(UNNotificationCategory(identifier: identifier, actions: actions + [markRead], intentIdentifiers: []))
        center.setNotificationCategories(categories)
        return identifier
    }

    /// Runs in the background, without opening the app.
    private static var markRead: UNNotificationAction {
        UNNotificationAction(
            identifier: markReadAction,
            title: String(localized: "Mark as Read"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "checkmark.circle")
        )
    }

    private static func notificationAction(_ action: Action) -> UNNotificationAction? {
        switch action.kind {
        case .view: UNNotificationAction(identifier: action.id, title: action.label, options: [.foreground])
        case .http, .copy: UNNotificationAction(identifier: action.id, title: action.label)
        case .broadcast, nil: nil
        }
    }
}
