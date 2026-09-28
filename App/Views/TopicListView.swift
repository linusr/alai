import SwiftUI
import SwiftData
import NtfyKit

struct TopicListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Query(sort: \Subscription.createdAt) private var subscriptions: [Subscription]
    @State private var isAddingTopic = false
    @State private var isBrowsing = false
    @Environment(ServerDirectory.self) private var servers
    @State private var pendingUnsubscribe: Subscription?

    private var sorted: [Subscription] {
        subscriptions.sorted { ($0.latestMessage?.time ?? $0.createdAt) > ($1.latestMessage?.time ?? $1.createdAt) }
    }

    var body: some View {
        topicList
            .navigationTitle("Topics")
            .homeActions()
            .sheet(isPresented: $isAddingTopic) { AddTopicView() }
            .sheet(isPresented: $isBrowsing) {
                if let server = servers.defaultServer {
                    NavigationStack {
                        BrowseTopicsView(server: server)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done", role: .confirm) { isBrowsing = false }
                                }
                            }
                    }
                }
            }
            .confirmationDialog(
                "Unsubscribe from \(pendingUnsubscribe?.title ?? "")?",
                isPresented: Binding(get: { pendingUnsubscribe != nil }, set: { if !$0 { pendingUnsubscribe = nil } }),
                titleVisibility: .visible
            ) {
                Button("Unsubscribe", role: .destructive) {
                    if let subscription = pendingUnsubscribe {
                        if router.selectedTopicKey == subscription.key { router.topicPath = [] }
                        Task { await model.unsubscribe(subscription) }
                    }
                }
            } message: {
                Text("Its messages will be removed from this device.")
            }
    }

    private var topicList: some View {
        List {
            if !subscriptions.isEmpty {
                NavigationLink(value: Router.allNotifications) {
                    AllNotificationsRow(unread: subscriptions.reduce(0) { $0 + $1.unreadCount })
                }
            }
            ForEach(sorted) { subscription in
                NavigationLink(value: subscription.key) {
                    TopicRow(subscription: subscription)
                }
                    .swipeActions(edge: .trailing) {
                        Button("Unsubscribe", systemImage: "trash", role: .destructive) {
                            pendingUnsubscribe = subscription
                        }
                        Button(subscription.isMuted ? "Unmute" : "Mute", systemImage: subscription.isMuted ? "bell" : "bell.slash") {
                            Task { await model.setMuted(subscription, !subscription.isMuted) }
                        }
                        .tint(.indigo)
                    }
                    .swipeActions(edge: .leading) {
                        if subscription.unreadCount > 0 {
                            Button("Read", systemImage: "checkmark.circle") {
                                Task { await model.markRead(subscription) }
                            }
                            .tint(.blue)
                        }
                    }
            }
        }
        .refreshable { await model.refreshAll() }
        .overlay {
            if subscriptions.isEmpty {
                ContentUnavailableView {
                    Label("No Topics Yet", systemImage: "bell.badge")
                } description: {
                    Text("Subscribe to a topic to receive its messages here and as notifications.")
                } actions: {
                    Button("Add Topic") { isAddingTopic = true }
                        .buttonStyle(.glassProminent)
                    if servers.defaultServer != nil {
                        Button("Browse Server Topics") { isBrowsing = true }
                    }
                }
            }
        }
    }
}

private struct AllNotificationsRow: View {
    let unread: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 11))
                .accessibilityHidden(true)
            Text("All Notifications").font(.headline)
            Spacer()
            if unread > 0 {
                Text(unread, format: .number)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: .capsule)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TopicRow: View {
    let subscription: Subscription

    var body: some View {
        HStack(spacing: 12) {
            TopicIcon(symbol: subscription.symbol, tint: subscription.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(subscription.title)
                        .font(.headline)
                        .lineLimit(1)
                    if subscription.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let latest = subscription.latestMessage {
                        Text(latest.time, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if subscription.unreadCount > 0 {
                        Text(subscription.unreadCount, format: .number)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(subscription.tint.color, in: .capsule)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        guard let message = subscription.latestMessage?.message else {
            return ServerURL.shortDisplay(subscription.serverURL) + "/" + subscription.topic
        }
        let body = NotificationFormatter.bodyText(message)
        guard let title = message.title, !title.isEmpty else { return body }
        return "\(title): \(body)"
    }
}

extension View {
    /// Settings and Add Topic in the navigation bar, shared by the home tabs.
    func homeActions() -> some View {
        modifier(HomeActions())
    }
}

private struct HomeActions: ViewModifier {
    @State private var isAddingTopic = false
    @State private var isShowingSettings = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Topic", systemImage: "plus") { isAddingTopic = true }
                }
            }
            .sheet(isPresented: $isAddingTopic) { AddTopicView() }
            .sheet(isPresented: $isShowingSettings) { SettingsView() }
    }
}
