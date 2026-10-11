import UIKit

/// Home Screen quick actions. Mark All as Read appears only while something is unread.
@MainActor
enum QuickActions {
    static let markAllRead = "me.4vr.alai.markAllRead"

    static func update(unread: Int) {
        UIApplication.shared.shortcutItems = unread > 0 ? [
            UIApplicationShortcutItem(
                type: markAllRead,
                localizedTitle: String(localized: "Mark All as Read"),
                localizedSubtitle: String(localized: "\(unread) unread"),
                icon: UIApplicationShortcutIcon(systemImageName: "checkmark.circle"),
                userInfo: nil
            ),
        ] : []
    }

    @discardableResult
    static func perform(_ item: UIApplicationShortcutItem, model: AppModel) -> Bool {
        guard item.type == markAllRead else { return false }
        Task { await model.markAllRead() }
        return true
    }
}

/// Receives quick actions chosen while the app is already running; cold launches arrive in
/// `AppDelegate.application(_:configurationForConnecting:options:)`.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        guard let model = AppDelegate.shared?.model else { return false }
        return QuickActions.perform(shortcutItem, model: model)
    }
}
