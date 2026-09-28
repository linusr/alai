import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(ServerDirectory.self) private var servers
    @Environment(Router.self) private var router
    @Query(sort: \Subscription.createdAt) private var subscriptions: [Subscription]
    @Environment(AppModel.self) private var model
    @AppStorage("homeTab") private var tab = HomeTab.topics
    @State private var query = ""
    @State private var isSearching = false

    var body: some View {
        @Bindable var router = router
        if servers.servers.isEmpty {
            OnboardingView()
        } else {
            TabView(selection: $tab) {
                Tab("Topics", systemImage: "bell.badge", value: HomeTab.topics) {
                    NavigationStack(path: $router.topicPath) {
                        TopicListView()
                            .navigationDestination(for: String.self) { key in
                                if key == Router.allNotifications {
                                    AllNotificationsView()
                                } else if let subscription = subscriptions.first(where: { $0.key == key }) {
                                    TopicView(subscription: subscription)
                                        .id(subscription.key)
                                } else {
                                    ContentUnavailableView("Topic Not Found", systemImage: "bell.slash")
                                }
                            }
                    }
                }
                Tab("Calendar", systemImage: "calendar", value: HomeTab.calendar) {
                    NavigationStack {
                        CalendarHome()
                            .navigationTitle("Calendar")
                            .navigationBarTitleDisplayMode(.inline)
                            .homeActions()
                    }
                }
                Tab(value: HomeTab.search, role: .search) {
                    NavigationStack { SearchView(query: query) }
                }
            }
            .searchable(text: $query, isPresented: $isSearching, prompt: "Messages")
            #if DEBUG
            .onAppear {
                if let seeded = UserDefaults.standard.string(forKey: "searchQuery") { query = seeded }
                if tab == .search { isSearching = true }
            }
            #endif
            // A notification, widget or Spotlight result that opens a topic shows it in the Topics tab
            .onChange(of: router.openRequest) { if tab != .topics { tab = .topics } }
            .sheet(item: Binding(
                get: { router.openedMessageKey.flatMap { model.store.message(key: $0) } },
                set: { if $0 == nil { router.openedMessageKey = nil } }
            )) { stored in
                OpenedMessage(stored: stored)
            }
            #if DEBUG
            .sheet(item: Binding(get: { router.debugScreen.map(DebugScreen.init) }, set: { router.debugScreen = $0?.id })) { screen in
                screen.view(server: servers.defaultServer, subscription: subscriptions.first)
            }
            #endif
        }
    }
}

enum HomeTab: String {
    case topics, calendar, search
}

struct OnboardingView: View {
    @State private var isAddingServer = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bell.badge.waveform.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 3)))
            VStack(spacing: 8) {
                Text("Your notifications,\nyour server")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Connect to your notification server to receive instant notifications from scripts, services and devices.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                isAddingServer = true
            } label: {
                Text("Connect Server").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(32)
        .sheet(isPresented: $isAddingServer) {
            AddServerView()
        }
    }
}

#if DEBUG
@MainActor
private struct DebugScreen: Identifiable {
    let id: String

    @ViewBuilder
    func view(server: URL?, subscription: Subscription?) -> some View {
        if id == "browse", let server {
            NavigationStack { BrowseTopicsView(server: server) }
        } else if id == "tokens", let server {
            NavigationStack { AccessTokensView(server: server) }
        } else if id == "devicekey", let subscription {
            DeviceKeyView(subscription: subscription)
        } else if id == "addtopic" {
            AddTopicView()
        } else {
            Text("Unknown screen \(id)")
        }
    }
}
#endif
