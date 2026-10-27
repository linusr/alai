import CryptoKit
import Foundation
import NtfyKit

/// Mirrors servers and topic subscriptions through iCloud key-value storage, so every device on the same
/// iCloud account has the same topics; credentials follow through iCloud Keychain. Read state and muting
/// stay per device.
///
/// Each server and topic is its own record, and a device only writes records it changed, with removals left
/// as dated tombstones. A device that has not downloaded the iCloud state yet therefore cannot erase other
/// devices' topics, and a tombstone never removes a topic subscribed again after it.
@MainActor
final class CloudSync {
    struct TopicFields: Codable, Equatable {
        let displayName: String?
        let symbol: String
        let tint: String
    }

    /// A server (no topic) or topic record, or its tombstone when `isDeleted` is set.
    private struct Record: Codable, Equatable {
        let server: String
        let topic: String?
        var fields: TopicFields?
        var isDeleted: Bool
        var updated: Date
    }

    /// Keys are hashes: iCloud key names are limited to 64 bytes, which a server URL plus topic can exceed.
    private static let keyPrefix = "sync."
    /// The records as of the last upload or applied remote change, so changes on either side can be told apart.
    private static let syncedKey = "cloudSyncedState"
    /// Long enough for every device to have seen a removal; older tombstones are deleted to stay within iCloud's 1024-key limit.
    private static let tombstoneLifetime: TimeInterval = 30 * 86_400
    /// A record this device wrote within this window but iCloud lacks was discarded before iCloud's first
    /// download and is written again. An older one was removed elsewhere and its tombstone has expired.
    private static let rewriteWindow: TimeInterval = 86_400

    private let store = NSUbiquitousKeyValueStore.default
    private unowned let model: AppModel
    /// Off until `start()`, so publishing never uploads before the first merge with iCloud.
    var isEnabled = false
    /// Suppresses uploads while a remote change is half applied.
    private var isApplying = false
    /// Remote changes apply one at a time, since applying awaits network work.
    private var applying: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            MainActor.assumeIsolated { self?.scheduleApply(accountChanged: reason == NSUbiquitousKeyValueStoreAccountChange) }
        }
        store.synchronize()
        scheduleApply(accountChanged: false)
    }

    private func scheduleApply(accountChanged: Bool) {
        let previous = applying
        applying = Task {
            await previous?.value
            if accountChanged {
                // Another account's records: merge without honoring its tombstones or this device's history
                saveSynced([:])
            }
            await applyRemote(honorTombstones: !accountChanged)
            upload()
        }
    }

    /// Writes this device's changes since the last sync, plus any of its items iCloud lacks, which covers
    /// writes iCloud discarded before its first download finished.
    func upload() {
        guard isEnabled, !isApplying else { return }
        let previous = syncedState()
        var synced = previous
        let local = localRecords(synced: synced)
        let remote = remoteRecords()
        // Keys whose records this version cannot decode still count as present, so it never overwrites them
        let remoteKeys = Set(store.dictionaryRepresentation.keys)
        let now = Date.now
        for (key, record) in local {
            let changedHere = synced[key] == nil || synced[key]?.fields != record.fields
            let discarded = !remoteKeys.contains(key) && synced[key].map { now.timeIntervalSince($0.updated) < Self.rewriteWindow } ?? false
            guard changedHere || discarded else { continue }
            var written = record
            written.updated = now
            write(written, key: key)
            synced[key] = written
        }
        for (key, record) in synced where local[key] == nil {
            // An existing tombstone keeps its date, so a late device cannot extend it over a newer subscription
            if remote[key]?.isDeleted != true {
                write(Record(server: record.server, topic: record.topic, fields: nil, isDeleted: true, updated: now), key: key)
            }
            synced[key] = nil
        }
        for (key, record) in remote where record.isDeleted && now.timeIntervalSince(record.updated) > Self.tombstoneLifetime {
            store.removeObject(forKey: key)
        }
        if synced != previous { saveSynced(synced) }
    }

    /// Forgets what this device last synced, so its next upload treats every local item as new.
    static func forgetSyncedState() {
        UserDefaults.standard.removeObject(forKey: syncedKey)
    }

    // MARK: Records

    private static func key(server: String, topic: String?) -> String {
        let identity = topic.map { "\(server)\n\($0)" } ?? server
        let digest = SHA256.hash(data: Data(identity.utf8))
        return keyPrefix + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Every server and topic on this device, keyed as in iCloud. A synced color this app version does not
    /// know keeps its name, since the local topic can only hold a known color.
    private func localRecords(synced: [String: Record]) -> [String: Record] {
        var records: [String: Record] = [:]
        for server in model.servers.servers {
            records[Self.key(server: server.absoluteString, topic: nil)] = Record(server: server.absoluteString, topic: nil, fields: nil, isDeleted: false, updated: .distantPast)
        }
        for subscription in model.store.subscriptions() where !subscription.isDeleted {
            let key = Self.key(server: subscription.baseURL, topic: subscription.topic)
            var tint = subscription.tint.rawValue
            if let syncedTint = synced[key]?.fields?.tint, TopicTint(rawValue: syncedTint) == nil {
                tint = syncedTint
            }
            let name = subscription.displayName.flatMap { $0.isEmpty ? nil : $0 }
            let fields = TopicFields(displayName: name, symbol: subscription.symbol, tint: tint)
            records[key] = Record(server: subscription.baseURL, topic: subscription.topic, fields: fields, isDeleted: false, updated: .distantPast)
        }
        return records
    }

    private func syncedState() -> [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: Self.syncedKey),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveSynced(_ state: [String: Record]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: Self.syncedKey)
    }

    private func write(_ record: Record, key: String) {
        store.set(try? JSONEncoder().encode(record), forKey: key)
    }

    private func remoteRecords() -> [String: Record] {
        var records: [String: Record] = [:]
        for (key, value) in store.dictionaryRepresentation where key.hasPrefix(Self.keyPrefix) {
            guard let data = value as? Data, let record = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            records[key] = record
        }
        return records
    }

    // MARK: Applying remote changes

    /// Applies records that changed remotely since this device last synced them. Records that match the
    /// last synced state are left alone, so a local edit not yet uploaded is never reverted.
    private func applyRemote(honorTombstones: Bool) async {
        let records = remoteRecords()
        guard !records.isEmpty else { return }
        var synced = syncedState()
        var changed = false
        isApplying = true
        defer { isApplying = false }

        for (key, record) in records where record.topic == nil {
            guard let server = URL(string: record.server) else { continue }
            if record.isDeleted {
                guard honorTombstones else { continue }
                if model.servers.servers.contains(server) {
                    await model.removeServer(server)
                    changed = true
                }
                synced[key] = nil
            } else {
                if !model.servers.servers.contains(server) {
                    model.servers.adopt(server)
                    changed = true
                }
                synced[key] = record
            }
        }

        let context = model.container.mainContext
        let subscriptions = model.store.subscriptions().filter { !$0.isDeleted }
        for (key, record) in records {
            guard let topic = record.topic, let server = URL(string: record.server) else { continue }
            let existing = subscriptions.first { $0.baseURL == record.server && $0.topic == topic }
            if record.isDeleted {
                guard honorTombstones else { continue }
                // A topic subscribed after the removal was recorded is a new subscription, not a stale one
                if let existing, existing.createdAt < record.updated {
                    if model.router.selectedTopicKey == existing.key { model.router.topicPath = [] }
                    SpotlightIndex.remove(topicKey: existing.key)
                    context.delete(existing)
                    changed = true
                }
                if existing == nil || existing?.isDeleted == true { synced[key] = nil }
            } else if let fields = record.fields, synced[key]?.fields != fields || existing == nil {
                // Synced but gone locally: an unsubscribe on this device that has not been uploaded yet
                if existing == nil, synced[key] != nil { continue }
                // Topics arrive under their server, never on their own
                guard model.servers.servers.contains(server) else { continue }
                if let existing {
                    existing.displayName = fields.displayName
                    existing.symbol = fields.symbol
                    if let tint = TopicTint(rawValue: fields.tint) { existing.tint = tint }
                } else {
                    context.insert(Subscription(baseURL: server, topic: topic, displayName: fields.displayName, symbol: fields.symbol, tint: TopicTint(rawValue: fields.tint) ?? .blue))
                }
                changed = true
                synced[key] = record
            }
        }

        try? context.save()
        saveSynced(synced)
        guard changed else { return }
        isApplying = false
        await model.refreshAll()
        await model.subscriptionsChanged()
        await model.requestNotificationPermission()
    }
}
