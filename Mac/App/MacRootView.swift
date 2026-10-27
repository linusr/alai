import SwiftUI
import SwiftData
import NtfyKit

/// The Mac window: a sidebar of feeds and topics beside the selected feed, in place of the iPhone's tabs.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ServerDirectory.self) private var servers
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Subscription.createdAt) private var subscriptions: [Subscription]
    @State private var query = ""
    @State private var pendingUnsubscribe: Subscription?

    private var sorted: [Subscription] {
        // A query can still hold models deleted in the same update, such as when a server is removed
        subscriptions.filter { !$0.isDeleted }.sorted { ($0.latestMessage?.time ?? $0.createdAt) > ($1.latestMessage?.time ?? $1.createdAt) }
    }

    private var selection: Binding<String?> {
        Binding(get: { router.topicPath.last }, set: { router.topicPath = $0.map { [$0] } ?? [] })
    }

    var body: some View {
        content
            .sheet(item: Bindable(router).presentedSheet) { sheet in
                switch sheet {
                case .newTopic:
                    AddTopicView().frame(minWidth: 460, minHeight: 520)
                case .browse(let server):
                    NavigationStack {
                        BrowseTopicsView(server: server)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { router.presentedSheet = nil }
                                }
                            }
                    }
                    .frame(minWidth: 460, minHeight: 520)
                }
            }
            .onAppear {
                router.openMainWindow = { [openWindow] in
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if servers.servers.isEmpty {
            OnboardingView()
                .frame(minWidth: 480, minHeight: 520)
        } else {
            NavigationSplitView {
                sidebar
            } detail: {
                NavigationStack { detail }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Messages")
            .sheet(item: Binding(
                get: { router.openedMessageKey.map(OpenedMessageKey.init) },
                set: { router.openedMessageKey = $0?.id }
            )) { opened in
                if let stored = model.store.message(key: opened.id) {
                    OpenedMessage(stored: stored).frame(minWidth: 460, minHeight: 400)
                } else {
                    ContentUnavailableView("Message Not Found", systemImage: "tray")
                        .frame(minWidth: 360, minHeight: 240)
                }
            }
            .confirmationDialog(
                "Unsubscribe from \(pendingUnsubscribe.flatMap { $0.isDeleted ? nil : $0.title } ?? "")?",
                isPresented: Binding(get: { pendingUnsubscribe != nil }, set: { if !$0 { pendingUnsubscribe = nil } })
            ) {
                Button("Unsubscribe", role: .destructive) {
                    if let subscription = pendingUnsubscribe {
                        if router.selectedTopicKey == subscription.key { router.topicPath = [] }
                        Task { await model.unsubscribe(subscription) }
                    }
                }
            } message: {
                Text("It is removed, with its messages, from all your devices that share this iCloud account.")
            }
        }
    }

    private var sidebar: some View {
        List(selection: selection) {
            Section {
                AllNotificationsRow(unread: sorted.reduce(0) { $0 + $1.unreadCount })
                    .tag(Router.allNotifications)
                Label("Calendar", systemImage: "calendar")
                    .tag(Router.calendar)
            }
            Section("Topics") {
                ForEach(sorted) { subscription in
                    TopicRow(subscription: subscription)
                        .tag(subscription.key)
                        .contextMenu { contextMenu(for: subscription) }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        .refreshable { await model.refreshAll() }
        .toolbar {
            ToolbarItem {
                Menu("Add Topic", systemImage: "plus") {
                    Button("New Topic…", systemImage: "square.and.pencil") { router.presentedSheet = .newTopic }
                    Section("Subscribe to Existing") {
                        ForEach(servers.servers, id: \.self) { server in
                            Button(servers.servers.count > 1 ? "Browse \(ServerURL.shortDisplay(server))…" : "Browse Topics…",
                                   systemImage: "list.bullet.rectangle") { router.presentedSheet = .browse(server) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for subscription: Subscription) -> some View {
        Button("Mark as Read", systemImage: "checkmark.circle") { Task { await model.markRead(subscription) } }
            .disabled(subscription.unreadCount == 0)
        Button(subscription.isMuted ? "Unmute" : "Mute", systemImage: subscription.isMuted ? "bell" : "bell.slash") {
            Task { await model.setMuted(subscription, !subscription.isMuted) }
        }
        Divider()
        Button("Unsubscribe…", systemImage: "trash", role: .destructive) { pendingUnsubscribe = subscription }
    }

    @ViewBuilder
    private var detail: some View {
        if !query.isEmpty {
            SearchView(query: query)
        } else if let key = router.topicPath.last {
            if key == Router.allNotifications {
                AllNotificationsView()
            } else if key == Router.calendar {
                CalendarHome().navigationTitle("Calendar")
            } else if let subscription = subscriptions.first(where: { !$0.isDeleted && $0.key == key }) {
                TopicView(subscription: subscription).id(subscription.key)
            } else {
                ContentUnavailableView("Topic Not Found", systemImage: "bell.slash")
            }
        } else {
            ContentUnavailableView("No Topic Selected", systemImage: "bell.badge", description: Text("Choose a topic in the sidebar."))
        }
    }
}

private struct OpenedMessageKey: Identifiable {
    let id: String
}
