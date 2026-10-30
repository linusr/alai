#if DEBUG
import Foundation
import OSLog
import NtfyKit

/// Launch arguments for simulator runs and screenshots:
/// `-seedServer http://localhost:8080 -seedUser ben -seedPassword pw -seedTopics backups,alerts=Alerts -openTopic alerts`
/// (a seeded topic takes an optional display name after `=`;
/// `-openTopic all` opens All Notifications (`calendar` opens the Calendar on Mac), `-homeTab calendar|search` picks the tab, `-searchQuery disk` prefills search),
/// plus `-openScreen browse|tokens|devicekey|addtopic` to open a screen directly.
/// `-resetState YES` removes every server, topic and device-only credential on the device; iCloud is left alone.
@MainActor
enum DebugSeed {
    private static var didOpenTopic = false

    /// Seeded, reset and previously seeded runs, which stay out of iCloud sync and iCloud Keychain.
    static var holdsDemoData: Bool {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: "seedServer") != nil || defaults.bool(forKey: "resetState") || defaults.bool(forKey: "debugSeeded")
    }

    static func apply(to model: AppModel) async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "resetState") {
            for server in model.servers.servers {
                await model.removeServer(server)
            }
            CloudSync.forgetSyncedState()
            defaults.removeObject(forKey: "debugSeeded")
            Logger(subsystem: "me.4vr.alai", category: "DebugSeed").notice("Reset: \(model.servers.servers.count) servers, \(model.store.subscriptions().count) topics remain")
            return
        }
        guard let server = defaults.string(forKey: "seedServer").flatMap(URL.init(string:)) else { return }
        defaults.set(true, forKey: "debugSeeded")
        if !model.servers.servers.contains(server) {
            let credential = defaults.string(forKey: "seedUser").map { ServerCredential.basic(username: $0, password: defaults.string(forKey: "seedPassword") ?? "") }
            do {
                try model.servers.add(server, credential: credential)
            } catch {
                Logger(subsystem: "me.4vr.alai", category: "DebugSeed").error("Could not add \(server): \(error)")
            }
            await model.importTopics(from: server)
        }
        let existing = Set(model.store.subscriptions().map(\.topic))
        let tints = TopicTint.allCases
        let symbols = Subscription.symbolChoices
        let seeded = (defaults.string(forKey: "seedTopics") ?? "").split(separator: ",").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
        for (index, entry) in seeded.enumerated() where !entry[0].isEmpty && !existing.contains(entry[0]) {
            model.container.mainContext.insert(Subscription(baseURL: server, topic: entry[0], displayName: entry.count > 1 ? entry[1] : nil, symbol: symbols[(index * 5 + 1) % symbols.count], tint: tints[(index * 3) % tints.count]))
        }
        try? model.container.mainContext.save()
        if let topic = defaults.string(forKey: "openTopic"), !didOpenTopic {
            didOpenTopic = true
            model.router.show(topicKey: [Router.allNotifications, Router.calendar].contains(topic) ? topic : topicKey(baseURL: server, topic: topic))
        }
        if let screen = defaults.string(forKey: "openScreen"), model.router.debugScreen == nil {
            model.router.debugScreen = screen
            defaults.removeObject(forKey: "openScreen")
        }
    }
}
#endif
