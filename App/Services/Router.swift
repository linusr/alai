import Foundation
#if os(macOS)
import AppKit
#endif
import Observation
import NtfyKit

/// Navigation state shared with notification handling, so a tapped notification opens its topic.
@Observable
@MainActor
final class Router {
    /// Screens pushed on the Topics tab: topic keys, or `Router.allNotifications` for the cross-topic feed.
    var topicPath: [String] = []

    /// The topic selected in the navigation, if any.
    var selectedTopicKey: String? { topicPath.last }

    /// The topic the user is looking at: selected, with the app in front. A Mac app keeps its selection
    /// behind other apps.
    var visibleTopicKey: String? {
        #if os(macOS)
        guard NSApplication.shared.isActive, let window = NSApplication.shared.mainWindow, window.isVisible,
              window.identifier?.rawValue.hasPrefix("main") == true
        else { return nil }
        #endif
        return selectedTopicKey
    }

    static let allNotifications = "all"
    /// The calendar, which the Mac sidebar lists alongside the topics.
    static let calendar = "calendar"

    /// Sheets the Mac menu bar opens over the main window.
    enum Sheet: Hashable, Identifiable {
        case newTopic
        case browse(URL)
        var id: Self { self }
    }

    var presentedSheet: Sheet?

    /// Set when something outside the Topics tab opens a topic, so the Topics tab comes forward.
    private(set) var openRequest = 0

    /// Brings the Mac main window forward and activates the app.
    var openMainWindow: (() -> Void)?

    func show(topicKey: String) {
        topicPath = [topicKey]
        openRequest += 1
        openMainWindow?()
    }

    /// A stored message key to show on top of its topic, e.g. from a Spotlight result.
    var openedMessageKey: String?

    func openMessage(key: String) {
        guard let separator = key.lastIndex(of: "#") else { return }
        show(topicKey: String(key[..<separator]))
        openedMessageKey = key
    }
    #if DEBUG
    var debugScreen: String?
    #endif

    /// Handles `alai://topic?key=<topic key>` links from widgets.
    func open(_ url: URL) {
        guard url.scheme == TopicStyle.linkScheme, url.host() == "topic",
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value
        else { return }
        show(topicKey: key)
    }
}
