import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(ServerDirectory.self) private var servers
    @Environment(Router.self) private var router
    @Query(sort: \Subscription.createdAt) private var subscriptions: [Subscription]

    var body: some View {
        @Bindable var router = router
        if servers.servers.isEmpty {
            OnboardingView()
        } else {
            NavigationSplitView {
                TopicListView(selection: $router.selectedTopicKey)
            } detail: {
                if router.selectedTopicKey == Router.allNotifications {
                    AllNotificationsView()
                } else if let subscription = subscriptions.first(where: { $0.key == router.selectedTopicKey }) {
                    TopicView(subscription: subscription)
                        .id(subscription.key)
                } else {
                    ContentUnavailableView("Select a Topic", systemImage: "bell.badge")
                }
            }
            #if DEBUG
            .sheet(item: Binding(get: { router.debugScreen.map(DebugScreen.init) }, set: { router.debugScreen = $0?.id })) { screen in
                screen.view(server: servers.defaultServer, subscription: subscriptions.first)
            }
            #endif
        }
    }
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
                Text("Connect to your ntfy server to receive instant notifications from scripts, services and devices.")
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
