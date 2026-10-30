import CryptoKit
import Foundation
import UserNotifications
import NtfyKit

/// Mirrors servers and topic subscriptions through iCloud key-value storage, so every device on the same
/// iCloud account has the same topics; credentials follow through iCloud Keychain. Each topic's read state
/// syncs as a "read through" time; muting stays per device.
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
    /// Keys the user removed on this device. Only these become tombstones, so an item missing because a
    /// local read failed is never announced as removed.
    private static let removalsKey = "cloudSyncRemovals"
    /// Each topic's read-through time: messages at or before it are read on every device.
    private static let readPrefix = "read."
    /// The latest read-through time this device has seen or written for each topic.
    private static let readStateKey = "cloudReadState"
    /// Long enough for every device to have seen a removal; older tombstones are deleted to stay within iCloud's
    /// 1024-key limit, which each topic uses two keys of: its record and its read-through time.
    private static let tombstoneLifetime: TimeInterval = 30 * 86_400

    private let store = NSUbiquitousKeyValueStore.default
    private unowned let model: AppModel
    /// Off until `start()`, so publishing never uploads before the first merge with iCloud.
    var isEnabled = false
    /// Read-through times waiting to be written; written a few seconds apart, since iCloud throttles frequent writes.
    private var pendingReadThrough: [String: Double] = [:]
    private var readThroughFlush: Task<Void, Never>?
    /// Suppresses uploads while a remote change is half applied.
    private var isApplying = false
    /// Uploads wait for the first apply, so a restored or new device cannot write over newer iCloud records.
    private var hasApplied = false
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
                Self.forgetSyncedState()
            }
            await applyRemote(honorTombstones: !accountChanged)
            hasApplied = true
            // Uploads records, and applies and writes read-through times
            await model.publish()
        }
    }

    /// Writes this device's changes since the last sync, plus any of its items iCloud lacks, which covers
    /// writes iCloud discarded before its first download finished.
    func upload() {
        guard isEnabled, hasApplied, !isApplying else { return }
        let previous = syncedState()
        var synced = previous
        let local = localRecords(synced: synced)
        let remote = remoteRecords()
        // Keys whose records this version cannot decode still count as present, so they are never re-sent as discarded
        let remoteKeys = Set(store.dictionaryRepresentation.keys)
        let now = Date.now
        for (key, record) in local {
            let changedHere = synced[key] == nil || synced[key]?.fields != record.fields
            // A record iCloud lacks that is younger than any tombstone was dropped by iCloud, not removed elsewhere
            let discarded = !remoteKeys.contains(key) && synced[key].map { now.timeIntervalSince($0.updated) < Self.tombstoneLifetime } ?? false
            guard changedHere || discarded else { continue }
            var written = record
            written.updated = now
            write(written, key: key)
            synced[key] = written
        }
        var removals = Self.removals
        for (key, removedAt) in removals {
            removals[key] = nil
            guard local[key] == nil, let known = synced[key] ?? remote[key] else { continue }
            // Dated when the user removed it, and an existing tombstone keeps its date, so neither an offline
            // device nor a late one can extend a removal over a newer subscription
            if remote[key]?.isDeleted != true {
                write(Record(server: known.server, topic: known.topic, fields: nil, isDeleted: true, updated: removedAt), key: key)
            }
            forgetReadThrough(key)
            synced[key] = nil
        }
        Self.removals = removals
        for (key, record) in remote where record.isDeleted && now.timeIntervalSince(record.updated) > Self.tombstoneLifetime {
            store.removeObject(forKey: key)
            store.removeObject(forKey: Self.readKey(key))
        }
        // Read-through times whose topic is neither here nor in iCloud belong to nothing
        for key in remoteKeys where key.hasPrefix(Self.readPrefix) {
            let recordKey = Self.keyPrefix + key.dropFirst(Self.readPrefix.count)
            if local[recordKey] == nil, !remoteKeys.contains(recordKey) { store.removeObject(forKey: key) }
        }
        if synced != previous { saveSynced(synced) }
    }

    /// Forgets what this device last synced, so its next upload treats every local item as new.
    static func forgetSyncedState() {
        UserDefaults.standard.removeObject(forKey: syncedKey)
        UserDefaults.standard.removeObject(forKey: removalsKey)
        UserDefaults.standard.removeObject(forKey: readStateKey)
    }

    /// Records that the user removed a server or topic here, for the next upload to announce.
    static func recordRemoval(server: URL, topic: String?) {
        removals[key(server: server.absoluteString, topic: topic)] = .now
    }

    private static var removals: [String: Date] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: removalsKey) as? [String: Double] ?? [:]
            return stored.mapValues(Date.init(timeIntervalSince1970:))
        }
        set { UserDefaults.standard.set(newValue.mapValues(\.timeIntervalSince1970), forKey: removalsKey) }
    }

    // MARK: Read state

    /// Marks messages read up to each topic's latest read-through time, from iCloud or written here, and
    /// removes the delivered notifications it covers.
    func applyReadState() async {
        guard isEnabled else { return }
        var known = Self.readState
        var advanced: Set<String> = []
        let ceiling = readThroughCeiling()
        for (key, value) in store.dictionaryRepresentation where key.hasPrefix(Self.readPrefix) {
            guard let time = value as? Double, time <= ceiling, time > known[key] ?? 0 else { continue }
            known[key] = time
            advanced.insert(key)
        }
        if !advanced.isEmpty { Self.readState = known }
        var readThrough: [String: Date] = [:]
        for subscription in model.store.subscriptions() where !subscription.isDeleted {
            let key = Self.readKey(Self.key(server: subscription.baseURL, topic: subscription.topic))
            guard let time = known[key] else { continue }
            let through = Date(timeIntervalSince1970: time)
            let newlyRead = subscription.messages.filter { !$0.isRead && $0.time <= through }
            newlyRead.forEach { $0.isRead = true }
            // A time from another device also covers notifications for messages not imported here yet
            if !newlyRead.isEmpty || advanced.contains(key) { readThrough[subscription.key] = through }
        }
        guard !readThrough.isEmpty else { return }
        try? model.container.mainContext.save()
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().filter { notification in
            guard let through = readThrough[notification.request.content.threadIdentifier] else { return false }
            return PushPayload(userInfo: notification.request.content.userInfo).map { $0.message.date <= through } ?? false
        }
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier))
    }

    /// Writes each topic's read-through time: the newest read message older than every unread one, so reading
    /// one message out of order, or one of several stored from the same second, does not mark the others read.
    /// A message arriving later with the same second as the read-through counts as read. The
    /// latest known time is written again whenever iCloud holds less, which an offline device's older write or
    /// a write iCloud discarded before its first download can leave.
    func uploadReadState() {
        guard isEnabled, hasApplied, !isApplying else { return }
        var known = Self.readState
        var changed = false
        let remote = remoteRecords()
        let ceiling = readThroughCeiling()
        for subscription in model.store.subscriptions() where !subscription.isDeleted {
            let recordKey = Self.key(server: subscription.baseURL, topic: subscription.topic)
            // A topic removed elsewhere loses its read-through time with it
            guard remote[recordKey]?.isDeleted != true else { continue }
            let key = Self.readKey(recordKey)
            let firstUnread = subscription.messages.lazy.filter { !$0.isRead }.map(\.time).min()
            let through = subscription.messages.lazy
                .filter { message in message.isRead && (firstUnread.map { message.time < $0 } ?? true) }
                .map(\.time).max()?.timeIntervalSince1970
            let target = max(known[key] ?? 0, through ?? 0)
            guard target > 0 else { continue }
            if target > known[key] ?? 0 {
                known[key] = target
                changed = true
            }
            // Below this device's time, or beyond any plausible one, iCloud's value is replaced with it
            let stored = store.object(forKey: key) as? Double ?? 0
            if stored < target || stored > ceiling {
                pendingReadThrough[key] = target
            }
        }
        if changed { Self.readState = known }
        guard !pendingReadThrough.isEmpty, readThroughFlush == nil else { return }
        readThroughFlush = Task {
            try? await Task.sleep(for: .seconds(5))
            flushReadThrough()
        }
    }

    /// Writes waiting read-through times now; called on the timer and when the app quits.
    func flushReadThrough() {
        readThroughFlush?.cancel()
        readThroughFlush = nil
        guard !pendingReadThrough.isEmpty else { return }
        for (key, time) in pendingReadThrough { store.set(time, forKey: key) }
        pendingReadThrough = [:]
        store.synchronize()
    }

    /// A read-through time beyond this was written from a wrong clock and would mark every later message
    /// read. Message times come from the servers, so the newest one bounds it along with this device's clock.
    private func readThroughCeiling() -> Double {
        let newest = model.store.subscriptions().compactMap { $0.latestMessage?.time }.max() ?? .distantPast
        return max(Date.now, newest).addingTimeInterval(86_400).timeIntervalSince1970
    }

    private func forgetReadThrough(_ recordKey: String) {
        let key = Self.readKey(recordKey)
        store.removeObject(forKey: key)
        var known = Self.readState
        if known.removeValue(forKey: key) != nil { Self.readState = known }
    }

    private static func readKey(_ recordKey: String) -> String {
        readPrefix + recordKey.dropFirst(keyPrefix.count)
    }

    private static var readState: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: readStateKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: readStateKey) }
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

    /// Applies records that changed remotely since this device last synced them; records that match the last
    /// synced state are left alone. Concurrent edits on two devices resolve to whichever reached iCloud last.
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
                // A server added after the removal was recorded is a new addition, not a stale one
                if model.servers.servers.contains(server), model.servers.addedDate(server) < record.updated {
                    await model.removeServer(server, announce: false)
                    for (topicKey, topicRecord) in synced where topicRecord.server == record.server && topicRecord.topic != nil {
                        synced[topicKey] = nil
                        forgetReadThrough(topicKey)
                    }
                    changed = true
                }
                // A kept server is announced again, since the tombstone otherwise hides it from other devices
                synced[key] = nil
            } else {
                // A removal on this device that has not been uploaded yet
                if Self.removals[key] != nil { continue }
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
                if let existing, !existing.isDeleted, existing.createdAt < record.updated {
                    if model.router.selectedTopicKey == existing.key { model.router.topicPath = [] }
                    SpotlightIndex.remove(topicKey: existing.key)
                    context.delete(existing)
                    forgetReadThrough(key)
                    changed = true
                } else if existing == nil {
                    forgetReadThrough(key)
                }
                // A kept topic is announced again, since the tombstone otherwise hides it from other devices
                synced[key] = nil
            } else if let fields = record.fields, synced[key]?.fields != fields || existing == nil {
                // An unsubscribe on this device that has not been uploaded yet
                if existing == nil, Self.removals[key] != nil { continue }
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
