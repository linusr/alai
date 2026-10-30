import Foundation
import Observation
import WatchConnectivity
import WidgetKit
import NtfyKit

/// Messages on the watch. The phone sends the server configuration and its latest snapshot; the watch
/// also polls the servers itself, so it stays current when the phone app is not running.
@Observable
@MainActor
final class WatchStore: NSObject, WCSessionDelegate {
    nonisolated private static let configurationKey = "configuration"

    private(set) var entries: [RecentSnapshot.Entry] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private var configuration: WatchConfiguration?
    private var unreadCount = 0

    override init() {
        super.init()
        let snapshot = RecentSnapshot.load()
        entries = snapshot.entries
        unreadCount = snapshot.unreadCount
        configuration = Self.loadConfiguration()
        #if DEBUG
        if let seeded = Self.debugConfiguration() { store(seeded) }
        #endif
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    var hasConfiguration: Bool { !(configuration?.topics.isEmpty ?? true) }

    /// Fetches the last day of messages for every topic and merges them into the snapshot.
    func refresh() async {
        guard let configuration, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastError = nil
        var merged = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for topic in configuration.topics {
            let client = NtfyClient(baseURL: topic.baseURL, credential: CredentialStore(accessGroup: nil, synchronizable: false).credential(for: topic.baseURL))
            do {
                for message in try await client.poll(topic: topic.topic, since: "24h") {
                    let entry = RecentSnapshot.Entry(topicKey: topic.key, topicTitle: topic.title, symbol: topic.symbol, tint: topic.tint, message: message)
                    merged[entry.id] = entry
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        let known = Set(configuration.topics.map(\.key))
        apply(RecentSnapshot(entries: merged.values.filter { known.contains($0.topicKey) }, unreadCount: unreadCount))
    }

    private func apply(_ snapshot: RecentSnapshot) {
        entries = snapshot.entries
        unreadCount = snapshot.unreadCount
        try? snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func store(_ configuration: WatchConfiguration) {
        let credentials = CredentialStore(accessGroup: nil, synchronizable: false)
        for server in configuration.servers {
            try? credentials.save(server.credential, for: server.url)
        }
        let withoutSecrets = WatchConfiguration(servers: configuration.servers.map { .init(url: $0.url, credential: nil) }, topics: configuration.topics)
        UserDefaults.standard.set(try? JSONEncoder().encode(withoutSecrets), forKey: Self.configurationKey)
        self.configuration = configuration
    }

    #if DEBUG
    /// `-seedServer http://localhost:8080 -seedUser ben -seedPassword pw -seedTopics backups,alerts`, for simulator
    /// runs where WatchConnectivity cannot pair ad-hoc signed builds.
    private static func debugConfiguration() -> WatchConfiguration? {
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: "seedServer").flatMap(URL.init(string:)) else { return nil }
        let credential = defaults.string(forKey: "seedUser").map { ServerCredential.basic(username: $0, password: defaults.string(forKey: "seedPassword") ?? "") }
        let topics = (defaults.string(forKey: "seedTopics") ?? "").split(separator: ",").map {
            WatchConfiguration.Topic(baseURL: server, topic: String($0), title: String($0), symbol: "bell.fill", tint: "blue")
        }
        return WatchConfiguration(servers: [.init(url: server, credential: credential)], topics: topics)
    }
    #endif

    private static func loadConfiguration() -> WatchConfiguration? {
        UserDefaults.standard.data(forKey: configurationKey).flatMap { try? JSONDecoder().decode(WatchConfiguration.self, from: $0) }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        receive(session.receivedApplicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    nonisolated private func receive(_ context: [String: Any]) {
        let configuration = (context[WatchConfiguration.contextKey] as? Data).flatMap { try? JSONDecoder().decode(WatchConfiguration.self, from: $0) }
        let snapshot = (context[WatchConfiguration.snapshotKey] as? Data).flatMap { try? JSONDecoder().decode(RecentSnapshot.self, from: $0) }
        Task { @MainActor in
            if let configuration { self.store(configuration) }
            if let snapshot { self.apply(snapshot) }
        }
    }
}
