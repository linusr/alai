import Foundation
import Observation
import NtfyKit

/// Navigation state shared with notification handling, so a tapped notification opens its topic.
@Observable
@MainActor
final class Router {
    /// A topic key, or `Router.allNotifications` for the cross-topic feed.
    var selectedTopicKey: String?

    static let allNotifications = "all"
    #if DEBUG
    var debugScreen: String?
    #endif

    /// Handles `alai://topic?key=<topic key>` links from widgets.
    func open(_ url: URL) {
        guard url.scheme == TopicStyle.linkScheme, url.host() == "topic",
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value
        else { return }
        selectedTopicKey = key
    }
}
