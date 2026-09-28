import Foundation
import Observation
import SwiftData
import UserNotifications
import WidgetKit
import NtfyKit

/// App-wide state and the operations views and notification handling share.
@Observable
@MainActor
final class AppModel {
    let container: ModelContainer
    let servers = ServerDirectory()
    let push = PushRegistrar()
    let router = Router()
    @ObservationIgnored private lazy var live = LiveUpdates(model: self)
    @ObservationIgnored private let watch = WatchBridge()
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    /// Seconds each server keeps messages, keyed by server URL string; persisted for offline launches.
    private(set) var retention: [String: Double] = UserDefaults.standard.dictionary(forKey: "serverRetention") as? [String: Double] ?? [:]

    /// Days the calendar reaches back: the longest retention among the servers, or 30 days
    /// (the Alai server default) until a server has reported it.
    var calendarHistoryDays: Int {
        guard let longest = retention.values.max(), longest > 0 else { return 30 }
        return max(1, Int((longest / 86_400).rounded(.up)))
    }

    init(inMemory: Bool = false) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try! ModelContainer(for: Subscription.self, StoredMessage.self, configurations: configuration)
    }

    var store: MessageStore { MessageStore(context: container.mainContext) }

    /// Subscribes to a topic, first reserving it for the signed-in account when `reserve` is set.
    func subscribe(server: URL, topic: String, displayName: String?, symbol: String, tint: TopicTint, reserve: TopicAccess? = nil) async throws {
        if let reserve {
            try await servers.client(for: server).reserve(topic: topic, everyone: reserve)
        }
        if store.subscription(baseURL: server, topic: topic) == nil {
            container.mainContext.insert(Subscription(baseURL: server, topic: topic, displayName: displayName, symbol: symbol, tint: tint))
            try? container.mainContext.save()
        }
        if let subscription = store.subscription(baseURL: server, topic: topic) {
            await refresh(subscription)
        }
        await subscriptionsChanged()
        await requestNotificationPermission()
    }

    /// Subscribes to the topics the signed-in account already has on a server: its reservations and
    /// the subscriptions synced from the ntfy web app. Returns how many topics were added.
    @discardableResult
    func importTopics(from server: URL) async -> Int {
        guard servers.credential(for: server) != nil,
              let account = try? await servers.client(for: server).account(), !account.isAnonymous
        else { return 0 }
        var candidates: [(topic: String, displayName: String?)] = (account.reservations ?? []).map { ($0.topic, nil) }
        for synced in account.subscriptions ?? [] where ServerURL.normalize(synced.baseURL) == server {
            candidates.append((synced.topic, synced.displayName))
        }
        let tints = TopicTint.allCases
        let symbols = Subscription.symbolChoices
        var added = 0
        for candidate in candidates where store.subscription(baseURL: server, topic: candidate.topic) == nil {
            container.mainContext.insert(Subscription(
                baseURL: server, topic: candidate.topic, displayName: candidate.displayName,
                symbol: symbols[(added * 5 + 1) % symbols.count], tint: tints[(added * 3) % tints.count]
            ))
            added += 1
        }
        guard added > 0 else { return 0 }
        try? container.mainContext.save()
        for subscription in store.subscriptions() where subscription.serverURL == server {
            await refresh(subscription)
        }
        await subscriptionsChanged()
        await requestNotificationPermission()
        return added
    }

    func unsubscribe(_ subscription: Subscription) async {
        SpotlightIndex.remove(topicKey: subscription.key)
        container.mainContext.delete(subscription)
        try? container.mainContext.save()
        await subscriptionsChanged()
    }

    func setMuted(_ subscription: Subscription, _ muted: Bool) async {
        subscription.isMuted = muted
        try? container.mainContext.save()
        await subscriptionsChanged()
    }

    func removeServer(_ server: URL) async {
        store.subscriptions().filter { $0.serverURL == server }.forEach(container.mainContext.delete)
        try? container.mainContext.save()
        await push.unregister(from: server, directory: servers)
        servers.remove(server)
        await subscriptionsChanged()
    }

    /// Pushes topic changes to everything that depends on the subscription list.
    func subscriptionsChanged() async {
        await registerForPush()
        live.restart()
        await publish()
    }

    // MARK: Delivery

    /// Imports pushed messages, then fetches anything missed from each server.
    func refreshAll() async {
        #if DEBUG
        await DebugSeed.apply(to: self)
        #endif
        store.ingestInbox()
        store.backfillSearchText()
        SpotlightIndex.rebuildIfNeeded(store)
        await updateRetention()
        isRefreshing = true
        defer { isRefreshing = false }
        lastError = nil
        for subscription in store.subscriptions() {
            await refresh(subscription)
        }
        await publish()
    }

    private func updateRetention() async {
        var updated = retention.filter { key, _ in servers.servers.contains { $0.absoluteString == key } }
        for server in servers.servers {
            if let seconds = try? await servers.client(for: server).account().limits?.messagesExpiryDuration, seconds > 0 {
                updated[server.absoluteString] = Double(seconds)
            }
        }
        guard updated != retention else { return }
        retention = updated
        UserDefaults.standard.set(updated, forKey: "serverRetention")
    }

    /// Fetches every message the servers still hold, including ones deleted on this device.
    /// Returns the number of messages that were new to the device.
    func syncAll() async -> Int {
        store.ingestInbox()
        var added = 0
        for subscription in store.subscriptions() {
            added += await refresh(subscription, full: true).count
        }
        await publish()
        return added
    }

    @discardableResult
    func refresh(_ subscription: Subscription, full: Bool = false) async -> [Message] {
        do {
            let since = full ? nil : subscription.lastMessageID
            let messages = try await servers.client(for: subscription.serverURL).poll(topic: subscription.topic, since: since)
            return store.apply(messages, to: subscription)
        } catch {
            lastError = "\(subscription.title): \(error.localizedDescription)"
            return []
        }
    }

    /// Applies messages received on the live stream.
    func receive(_ message: Message, from server: URL) async {
        guard let subscription = store.subscription(baseURL: server, topic: message.topic) else { return }
        guard !store.apply([message], to: subscription).isEmpty else { return }
        if router.selectedTopicKey == subscription.key {
            store.markAllRead(subscription)
        }
        await publish()
    }

    /// Background refresh: polls every topic and posts local notifications for new messages on topics
    /// whose server does not deliver them through APNs.
    func backgroundRefresh() async -> Bool {
        store.ingestInbox()
        var delivered = false
        for subscription in store.subscriptions() {
            let fresh = await refresh(subscription)
            guard !fresh.isEmpty, !subscription.isMuted, push.status[subscription.serverURL] != .registered else { continue }
            for message in fresh.suffix(5) {
                await LocalNotifications.post(message, baseURL: subscription.serverURL)
            }
            delivered = true
        }
        await publish()
        return delivered
    }

    func setLiveUpdates(active: Bool) {
        active ? live.restart() : live.stop()
    }

    func registerForPush() async {
        var topics: [URL: [String]] = Dictionary(uniqueKeysWithValues: servers.servers.map { ($0, []) })
        for subscription in store.subscriptions() where !subscription.isMuted {
            topics[subscription.serverURL, default: []].append(subscription.topic)
        }
        await push.register(topicsByServer: topics, directory: servers)
    }

    // MARK: Read state and publishing

    func markRead(_ subscription: Subscription) async {
        store.markAllRead(subscription)
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == subscription.key }
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier))
        await publish()
    }

    /// Updates the badge, the widgets' snapshot and the watch.
    func publish() async {
        let subscriptions = store.subscriptions()
        let unread = subscriptions.reduce(0) { $0 + $1.unreadCount }
        try? await UNUserNotificationCenter.current().setBadgeCount(unread)

        let entries = subscriptions.flatMap { subscription in
            subscription.messages.compactMap { stored in
                stored.message.map {
                    RecentSnapshot.Entry(topicKey: subscription.key, topicTitle: subscription.title, symbol: subscription.symbol, tint: subscription.tint.rawValue, message: $0)
                }
            }
        }
        let snapshot = RecentSnapshot(entries: entries, unreadCount: unread)
        try? snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()

        let configuration = WatchConfiguration(
            servers: servers.servers.map { WatchConfiguration.Server(url: $0, credential: servers.credential(for: $0)) },
            topics: subscriptions.map { WatchConfiguration.Topic(baseURL: $0.serverURL, topic: $0.topic, title: $0.title, symbol: $0.symbol, tint: $0.tint.rawValue) }
        )
        watch.send(configuration: configuration, snapshot: snapshot)
    }

    /// Asked after content is loaded, since the system prompt blocks until answered.
    private func requestNotificationPermission() async {
        #if DEBUG
        // Seeded simulator runs are for screenshots; the prompt would cover them
        if UserDefaults.standard.string(forKey: "seedServer") != nil { return }
        #endif
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}
