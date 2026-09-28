import SwiftUI
import SwiftData
import NtfyKit

/// Topics the signed-in account can see on a server. ntfy has no registry of topics, so this shows
/// reservations, the account's access grants, subscriptions synced from the web app and, for admins,
/// every user's grants and the topics with recent messages.
struct BrowseTopicsView: View {
    let server: URL
    @Environment(AppModel.self) private var model
    @Environment(ServerDirectory.self) private var servers
    @Query private var subscriptions: [Subscription]
    @State private var account: Account?
    @State private var users: [ServerUser] = []
    @State private var activeTopics: [String] = []
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        List {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            if let account {
                if account.isAnonymous {
                    Section {
                        Text("Sign in to this server to browse the topics you own and have access to.")
                            .foregroundStyle(.secondary)
                    }
                }
                topicSection("Reserved by You", footer: "Only you can change who may use these topics.", topics: (account.reservations ?? []).map {
                    BrowsedTopic(name: $0.topic, detail: $0.everyone.label)
                })
                topicSection("Synced from Web App", footer: nil, topics: (account.subscriptions ?? [])
                    .filter { ServerURL.normalize($0.baseURL) == server }
                    .map { BrowsedTopic(name: $0.topic, detail: $0.displayName) })
                if account.isAdmin {
                    ForEach(users, id: \.username) { user in
                        topicSection(sectionTitle(user, account: account), footer: nil, topics: browsableGrants(user.grants, account: account))
                    }
                    topicSection("Active on This Server", footer: "Topics with messages the server still holds.", topics: activeTopics.map {
                        BrowsedTopic(name: $0, detail: nil)
                    })
                } else {
                    topicSection("Shared with You", footer: nil, topics: browsableGrants(account.access, account: account))
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if let account, !account.isAnonymous, (account.reservations ?? []).isEmpty, (account.subscriptions ?? []).isEmpty,
                      (account.access ?? []).isEmpty, users.isEmpty, activeTopics.isEmpty {
                ContentUnavailableView("No Topics Found", systemImage: "magnifyingglass", description: Text("Reserve a topic when adding it, and it shows up here."))
            }
        }
        .navigationTitle("Browse \(ServerURL.shortDisplay(server))")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func topicSection(_ title: String, footer: String?, topics: [BrowsedTopic]) -> some View {
        if !topics.isEmpty {
            Section {
                ForEach(topics.sorted { $0.name < $1.name }) { topic in
                    BrowsedTopicRow(topic: topic, isSubscribed: isSubscribed(topic.name)) {
                        Task { try? await model.subscribe(server: server, topic: topic.name, displayName: nil, symbol: "bell.fill", tint: .blue) }
                    }
                }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    /// Grants other than the ones a reservation creates (owner read-write, everyone else's access)
    /// and deny-all rules, which block topics rather than offer them.
    private func browsableGrants(_ grants: [ServerUser.Grant]?, account: Account) -> [BrowsedTopic] {
        let reserved = Set((account.reservations ?? []).map(\.topic))
        return (grants ?? [])
            .filter { $0.permission != .denyAll && !reserved.contains($0.topic) }
            .map { BrowsedTopic(name: $0.topic, detail: $0.permission.grantLabel) }
    }

    private func sectionTitle(_ user: ServerUser, account: Account) -> String {
        switch user.username {
        case "*": String(localized: "Everyone")
        case account.username: String(localized: "Shared with You")
        default: String(localized: "Shared with \(user.username)")
        }
    }

    private func isSubscribed(_ topic: String) -> Bool {
        subscriptions.contains { $0.serverURL == server && $0.topic == topic }
    }

    private func load() async {
        let client = servers.client(for: server)
        do {
            let account = try await client.account()
            self.account = account
            users = account.isAdmin ? (try? await client.users()) ?? [] : []
            activeTopics = account.isAdmin ? (try? await client.activeTopics()) ?? [] : []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

private struct BrowsedTopic: Identifiable, Hashable {
    let name: String
    let detail: String?
    var id: String { name }
    /// Grants may use wildcards such as `backups_*`, which cannot be subscribed to.
    var isPattern: Bool { name.contains("*") }
}

private struct BrowsedTopicRow: View {
    let topic: BrowsedTopic
    let isSubscribed: Bool
    let subscribe: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.name).fontDesign(.monospaced)
                if let detail = topic.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if topic.isPattern {
                Text("Pattern").font(.caption).foregroundStyle(.secondary)
            } else if isSubscribed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Subscribed")
            } else {
                Button("Subscribe", systemImage: "plus.circle", action: subscribe)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .buttonStyle(.borderless)
            }
        }
    }
}
