import Foundation
import SwiftData
import NtfyKit

/// Applies incoming messages and events to the local database.
@MainActor
struct MessageStore {
    let context: ModelContext

    func subscriptions() -> [Subscription] {
        (try? context.fetch(FetchDescriptor<Subscription>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func subscription(baseURL: URL, topic: String) -> Subscription? {
        let base = baseURL.absoluteString
        var descriptor = FetchDescriptor<Subscription>(predicate: #Predicate { $0.baseURL == base && $0.topic == topic })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Returns the messages that were not stored before.
    @discardableResult
    func apply(_ messages: [Message], to subscription: Subscription) -> [Message] {
        var fresh: [Message] = []
        var changed: [StoredMessage] = []
        var removed: [String] = []
        for message in messages.sorted(by: { $0.time < $1.time }) {
            switch message.kind {
            case .message:
                let key = StoredMessage.key(subscription: subscription, sequenceID: message.effectiveSequenceID)
                if let existing = stored(key: key) {
                    guard existing.messageID != message.id, existing.time <= message.date else { continue }
                    existing.update(with: message)
                    changed.append(existing)
                } else {
                    let stored = StoredMessage(message: message, subscription: subscription)
                    context.insert(stored)
                    changed.append(stored)
                }
                fresh.append(message)
                subscription.lastMessageID = message.id
            case .messageDelete:
                if let stored = stored(key: StoredMessage.key(subscription: subscription, sequenceID: message.effectiveSequenceID)) {
                    removed.append(stored.key)
                    context.delete(stored)
                }
            case .messageClear:
                stored(key: StoredMessage.key(subscription: subscription, sequenceID: message.effectiveSequenceID))?.isRead = true
            default:
                continue
            }
        }
        try? context.save()
        SpotlightIndex.index(changed)
        SpotlightIndex.remove(keys: removed)
        return fresh
    }

    /// Fills in search text for messages stored before it existed.
    func backfillSearchText() {
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.searchText == "" })
        guard let messages = try? context.fetch(descriptor), !messages.isEmpty else { return }
        for stored in messages {
            if let message = stored.message { stored.searchText = StoredMessage.searchText(for: message) }
        }
        try? context.save()
    }

    func allMessages() -> [StoredMessage] {
        (try? context.fetch(FetchDescriptor<StoredMessage>())) ?? []
    }

    func message(key: String) -> StoredMessage? {
        stored(key: key)
    }

    /// Moves messages the notification service extension received into the database.
    func ingestInbox() {
        for item in Inbox().drain() {
            if let subscription = subscription(baseURL: item.baseURL, topic: item.message.topic) {
                apply([item.message], to: subscription)
            }
        }
    }

    func markRead(key: String) {
        guard let stored = stored(key: key), !stored.isRead else { return }
        stored.isRead = true
        try? context.save()
    }

    func markAllRead(_ subscription: Subscription) {
        subscription.messages.filter { !$0.isRead }.forEach { $0.isRead = true }
        try? context.save()
    }

    private func stored(key: String) -> StoredMessage? {
        var descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
