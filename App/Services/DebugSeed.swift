#if DEBUG
import Foundation
import OSLog
import NtfyKit

/// Launch arguments for simulator runs and screenshots:
/// `-seedServer http://localhost:8080 -seedUser ben -seedPassword pw -seedTopics backups,alerts -openTopic alerts`
/// (`-openTopic all` opens All Notifications, `-homeTab calendar|search` picks the tab, `-searchQuery disk` prefills search),
/// plus `-openScreen browse|tokens|devicekey|addtopic` to open a screen directly.
/// `-resetState YES` removes every server, credential and topic on the device.
@MainActor
enum DebugSeed {
    private static var didOpenTopic = false

    static func apply(to model: AppModel) async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "resetState") {
            for server in model.servers.servers {
                await model.removeServer(server)
            }
            defaults.removeObject(forKey: "cloudSyncedState")
            Logger(subsystem: "me.4vr.alai", category: "DebugSeed").notice("Reset: \(model.servers.servers.count) servers, \(model.store.subscriptions().count) topics remain")
            return
        }
        guard let server = defaults.string(forKey: "seedServer").flatMap(URL.init(string:)) else { return }
        if !model.servers.servers.contains(server) {
            let credential = defaults.string(forKey: "seedUser").map { ServerCredential.basic(username: $0, password: defaults.string(forKey: "seedPassword") ?? "") }
            try? model.servers.add(server, credential: credential)
            await model.importTopics(from: server)
        }
        let existing = Set(model.store.subscriptions().map(\.topic))
        let tints = TopicTint.allCases
        let symbols = Subscription.symbolChoices
        for (index, topic) in (defaults.string(forKey: "seedTopics") ?? "").split(separator: ",").map(String.init).enumerated() where !existing.contains(topic) {
            model.container.mainContext.insert(Subscription(baseURL: server, topic: topic, symbol: symbols[(index * 5 + 1) % symbols.count], tint: tints[(index * 3) % tints.count]))
        }
        try? model.container.mainContext.save()
        if let topic = defaults.string(forKey: "openTopic"), !didOpenTopic {
            didOpenTopic = true
            model.router.show(topicKey: topic == Router.allNotifications ? topic : topicKey(baseURL: server, topic: topic))
        }
        if let screen = defaults.string(forKey: "openScreen"), model.router.debugScreen == nil {
            model.router.debugScreen = screen
            defaults.removeObject(forKey: "openScreen")
        }
    }
}
#endif
