import CoreSpotlight
import UniformTypeIdentifiers
import NtfyKit

/// Keeps stored messages in the iPhone-wide Spotlight index. Items are keyed by the stored message key
/// and grouped under their topic key, so a topic's items can be removed together.
@MainActor
enum SpotlightIndex {
    /// Bumped when the indexed attributes change, so launch re-indexes everything once.
    private static let version = 1
    private static let versionKey = "spotlightIndexVersion"

    static func index(_ messages: [StoredMessage]) {
        let items = messages.compactMap(item)
        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items)
    }

    static func remove(keys: [String]) {
        guard !keys.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: keys)
    }

    static func remove(topicKey: String) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [topicKey])
    }

    /// Rebuilds the index when it was built by an older version of the app, or never.
    static func rebuildIfNeeded(_ store: MessageStore) {
        guard UserDefaults.standard.integer(forKey: versionKey) < version else { return }
        CSSearchableIndex.default().deleteAllSearchableItems { _ in
            Task { @MainActor in
                index(store.allMessages())
                UserDefaults.standard.set(version, forKey: versionKey)
            }
        }
    }

    private static func item(_ stored: StoredMessage) -> CSSearchableItem? {
        guard let message = stored.message, let subscription = stored.subscription else { return nil }
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        let body = NotificationFormatter.bodyText(message)
        if let title = message.title, !title.isEmpty {
            attributes.title = title
            attributes.contentDescription = "\(subscription.title) · \(body)"
        } else {
            attributes.title = subscription.title
            attributes.contentDescription = body
        }
        attributes.textContent = stored.searchText
        attributes.keywords = [subscription.topic, subscription.title] + (message.tags ?? [])
        attributes.contentCreationDate = stored.time
        attributes.containerTitle = subscription.title
        let item = CSSearchableItem(uniqueIdentifier: stored.key, domainIdentifier: subscription.key, attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }
}
