import Foundation
import NtfyKit

/// Mirrors servers and topic subscriptions through iCloud key-value storage, so every device on the same
/// iCloud account has the same topics; credentials follow through iCloud Keychain. Read state and muting
/// stay per device.
///
/// Each server and topic is its own key, and a device only writes the keys it changed, with removals left
/// as dated tombstones. A device that has not downloaded the iCloud state yet therefore cannot erase other
/// devices' topics, and a tombstone never removes a topic subscribed again after it.
@MainActor
final class CloudSync {
    struct TopicFields: Codable, Equatable {
        let displayName: String?
        let symbol: String
        let tint: String
    }

    /// A key's value, or a tombstone when `isDeleted` is set. Server records carry no fields.
    private struct Record: Codable {
        var fields: TopicFields?
        var isDeleted: Bool
        var updated: Date
    }

    private static let serverPrefix = "server|"
    private static let topicPrefix = "topic|"
    /// The local state as of the last upload or applied remote change, so the next upload writes only differences.
    private static let syncedKey = "cloudSyncedState"

    private let store = NSUbiquitousKeyValueStore.default
    private unowned let model: AppModel
    /// Off until `start()`, so publishing never uploads before the first merge with iCloud.
    var isEnabled = false
    /// Suppresses uploads while a remote change is half applied.
    private var isApplying = false

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.applyRemote() } }
        }
        store.synchronize()
        Task {
            await applyRemote()
            upload()
        }
    }

    /// Writes the servers and topics added, changed or removed on this device since the last sync.
    func upload() {
        guard isEnabled, !isApplying else { return }
        let local = localState()
        let synced = syncedState()
        guard local != synced else { return }
        let now = Date.now
        for (key, fields) in local where synced[key] != fields {
            write(Record(fields: fields, isDeleted: false, updated: now), key: key)
        }
        for key in synced.keys where local[key] == nil {
            write(Record(fields: nil, isDeleted: true, updated: now), key: key)
        }
        saveSynced(local)
    }

    // MARK: State

    /// Every server and topic on this device, keyed as in iCloud. Servers map to nil fields.
    private func localState() -> [String: TopicFields?] {
        var state: [String: TopicFields?] = [:]
        for server in model.servers.servers {
            state[Self.serverPrefix + server.absoluteString] = .some(nil)
        }
        for subscription in model.store.subscriptions() {
            state[Self.topicPrefix + subscription.baseURL + "|" + subscription.topic] = TopicFields(
                displayName: subscription.displayName, symbol: subscription.symbol, tint: subscription.tint.rawValue
            )
        }
        return state
    }

    private func syncedState() -> [String: TopicFields?] {
        guard let data = UserDefaults.standard.data(forKey: Self.syncedKey),
              let decoded = try? JSONDecoder().decode([String: TopicFields?].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveSynced(_ state: [String: TopicFields?]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: Self.syncedKey)
    }

    private func write(_ record: Record, key: String) {
        store.set(try? JSONEncoder().encode(record), forKey: key)
    }

    private func remoteRecords() -> [String: Record] {
        var records: [String: Record] = [:]
        for (key, value) in store.dictionaryRepresentation {
            guard key.hasPrefix(Self.serverPrefix) || key.hasPrefix(Self.topicPrefix),
                  let data = value as? Data, let record = try? JSONDecoder().decode(Record.self, from: data)
            else { continue }
            records[key] = record
        }
        return records
    }

    // MARK: Applying remote changes

    private func applyRemote() async {
        let records = remoteRecords()
        guard !records.isEmpty else { return }
        var synced = syncedState()
        let local = localState()
        var changed = false
        isApplying = true

        for (key, record) in records where key.hasPrefix(Self.serverPrefix) {
            guard let server = URL(string: String(key.dropFirst(Self.serverPrefix.count))) else { continue }
            if record.isDeleted {
                if local[key] != nil {
                    await model.removeServer(server)
                    changed = true
                }
                synced[key] = nil
            } else {
                if local[key] == nil {
                    model.servers.adopt(server)
                    changed = true
                }
                synced[key] = .some(nil)
            }
        }

        let context = model.container.mainContext
        let subscriptions = model.store.subscriptions()
        for (key, record) in records where key.hasPrefix(Self.topicPrefix) {
            let parts = key.dropFirst(Self.topicPrefix.count)
            guard let separator = parts.lastIndex(of: "|"), let server = URL(string: String(parts[..<separator])) else { continue }
            let topic = String(parts[parts.index(after: separator)...])
            let existing = subscriptions.first { $0.baseURL == server.absoluteString && $0.topic == topic }
            if record.isDeleted {
                // A topic subscribed after the removal was recorded is a new subscription, not a stale one
                if let existing, existing.createdAt < record.updated {
                    SpotlightIndex.remove(topicKey: existing.key)
                    context.delete(existing)
                    changed = true
                }
                synced[key] = nil
            } else if let fields = record.fields {
                let tint = TopicTint(rawValue: fields.tint) ?? .blue
                if let existing {
                    if local[key] != fields {
                        existing.displayName = fields.displayName
                        existing.symbol = fields.symbol
                        existing.tint = tint
                        changed = true
                    }
                } else {
                    context.insert(Subscription(baseURL: server, topic: topic, displayName: fields.displayName, symbol: fields.symbol, tint: tint))
                    changed = true
                }
                synced[key] = fields
            }
        }

        try? context.save()
        saveSynced(synced)
        isApplying = false
        guard changed else { return }
        await model.refreshAll()
        await model.subscriptionsChanged()
    }
}
