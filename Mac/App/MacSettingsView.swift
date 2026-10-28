import SwiftUI
import NtfyKit

/// The Mac Settings window: servers in a list beside the selected one's details, then general and about panes.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            Tab("Servers", systemImage: "server.rack") { ServersPane() }
            Tab("General", systemImage: "gearshape") {
                Form {
                    NotificationPermissionSection()
                    MessageSyncSection()
                }
            }
            Tab("About", systemImage: "info.circle") {
                Form { AboutSection() }
            }
        }
        .frame(width: 620, height: 460)
    }
}

private struct ServersPane: View {
    @Environment(ServerDirectory.self) private var servers
    @Environment(PushRegistrar.self) private var push
    @State private var selection: URL?
    @State private var isAddingServer = false
    @State private var pendingRemoval: URL?
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(servers.servers, id: \.self) { server in
                        ServerRow(server: server, isDefault: server == servers.defaultServer, status: push.status[server] ?? .unknown)
                            .tag(server)
                    }
                }
                .listStyle(.bordered)
                HStack(spacing: 0) {
                    Button("Add Server", systemImage: "plus") { isAddingServer = true }
                    Button("Remove Server", systemImage: "minus") { pendingRemoval = selection }
                        .disabled(selection == nil)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 220)
            .padding([.leading, .vertical])

            NavigationStack {
                if let selection, servers.servers.contains(selection) {
                    ServerDetailView(server: selection).id(selection)
                } else {
                    ContentUnavailableView("No Server Selected", systemImage: "server.rack", description: Text("Instant delivery needs a server with APNs enabled for this app."))
                }
            }
        }
        .onAppear { selection = selection ?? servers.defaultServer }
        .sheet(isPresented: $isAddingServer) { AddServerView().frame(minWidth: 440, minHeight: 380) }
        .confirmationDialog(
            "Remove \(pendingRemoval.map(ServerURL.shortDisplay) ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let server = pendingRemoval {
                    selection = nil
                    Task { await model.removeServer(server) }
                }
            }
        } message: {
            Text("Removes the server, its topics and messages, and its sign-in from all your devices that share this iCloud account.")
        }
    }
}
