import UIKit

/// Home Screen quick actions, declared statically in Info.plist so they exist before the first launch.
@MainActor
enum QuickActions {
    static let markAllRead = "me.4vr.alai.markAllRead"

    /// Removes dynamic items registered by 1.1 builds, which would duplicate the static one.
    static func clearDynamic() {
        UIApplication.shared.shortcutItems = []
    }

    @discardableResult
    static func perform(_ item: UIApplicationShortcutItem, model: AppModel) -> Bool {
        guard item.type == markAllRead else { return false }
        Task { await model.markAllRead() }
        return true
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        guard let model = AppDelegate.shared?.model else { return false }
        return QuickActions.perform(shortcutItem, model: model)
    }
}
