import SwiftUI
import UserNotifications
import NtfyKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ServerDirectory.self) private var servers
    @Environment(PushRegistrar.self) private var push
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isAddingServer = false
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var isSyncing = false
    @State private var syncResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(servers.servers, id: \.self) { server in
                        NavigationLink {
                            ServerDetailView(server: server)
                        } label: {
                            ServerRow(server: server, isDefault: server == servers.defaultServer, status: push.status[server] ?? .unknown)
                        }
                    }
                    Button("Add Server", systemImage: "plus") { isAddingServer = true }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("Instant delivery needs a server with APNs enabled for this app.")
                }

                Section("Notifications") {
                    LabeledContent("Permission") {
                        Text(authorizationLabel).foregroundStyle(authorization == .authorized ? .green : .orange)
                    }
                    Button("Notification Settings", systemImage: "gear") {
                        openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
                    }
                }

                Section {
                    Button {
                        Task {
                            isSyncing = true
                            let added = await model.syncAll()
                            syncResult = added == 0 ? String(localized: "Already up to date") : String(localized: "\(added) messages added")
                            isSyncing = false
                        }
                    } label: {
                        HStack {
                            Label("Sync All Messages", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if isSyncing {
                                ProgressView()
                            } else if let syncResult {
                                Text(syncResult).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isSyncing)
                } header: {
                    Text("Messages")
                } footer: {
                    Text("Downloads every message your servers still hold for your topics, including ones deleted on this iPhone. Servers keep messages only for a limited time, set by their cache duration.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link(destination: URL(string: "https://4vr.me/alai/support.html")!) {
                        Label("Help & Support", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://4vr.me/alai/privacy.html")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
            .sheet(isPresented: $isAddingServer) { AddServerView() }
            .task { authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
        }
    }

    private var authorizationLabel: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: String(localized: "Allowed")
        case .denied: String(localized: "Denied")
        default: String(localized: "Not requested")
        }
    }
}

private struct ServerRow: View {
    let server: URL
    let isDefault: Bool
    let status: PushRegistrar.Status

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(ServerURL.shortDisplay(server))
                if isDefault {
                    Text("Default").font(.caption2.bold()).foregroundStyle(.secondary)
                }
            }
            statusLabel.font(.caption)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .registered:
            Label("Instant delivery", systemImage: "bolt.fill").foregroundStyle(.green)
        case .unsupported:
            Label("APNs not enabled on server", systemImage: "bolt.slash").foregroundStyle(.orange)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(2)
        case .unknown:
            Label("Not registered yet", systemImage: "clock").foregroundStyle(.secondary)
        }
    }
}

private struct ServerDetailView: View {
    let server: URL
    @Environment(AppModel.self) private var model
    @Environment(ServerDirectory.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false

    var body: some View {
        Form {
            Section {
                LabeledContent("URL", value: server.absoluteString)
                LabeledContent("Sign-in", value: credentialLabel)
            }
            Section {
                NavigationLink {
                    BrowseTopicsView(server: server)
                } label: {
                    Label("Browse Topics", systemImage: "list.bullet.rectangle")
                }
                if servers.credential(for: server) != nil {
                    NavigationLink {
                        AccessTokensView(server: server)
                    } label: {
                        Label("Access Tokens", systemImage: "key")
                    }
                }
            }
            if server != servers.defaultServer {
                Button("Make Default") { servers.makeDefault(server) }
            }
            Section {
                Button("Remove Server", role: .destructive) { isConfirmingRemoval = true }
            } footer: {
                Text("Removes its topics and messages from this device.")
            }
        }
        .navigationTitle(ServerURL.shortDisplay(server))
        .confirmationDialog("Remove \(ServerURL.shortDisplay(server))?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await model.removeServer(server)
                    dismiss()
                }
            }
        }
    }

    private var credentialLabel: String {
        switch servers.credential(for: server) {
        case let .basic(username, _): username
        case .token: String(localized: "Access token")
        case nil: String(localized: "Anonymous")
        }
    }
}

struct AddServerView: View {
    private enum AuthMode: String, CaseIterable, Identifiable {
        case none = "None", password = "Username", token = "Token"
        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @Environment(ServerDirectory.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var authMode = AuthMode.none
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var isConnecting = false
    @State private var error: String?

    private var credential: ServerCredential? {
        switch authMode {
        case .none: nil
        case .password: .basic(username: username, password: password)
        case .token: .token(token)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("alerts.example.com", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                }
                Section("Sign In") {
                    Picker("Method", selection: $authMode) {
                        ForEach(AuthMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch authMode {
                    case .none:
                        EmptyView()
                    case .password:
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    case .token:
                        SecureField("tk_…", text: $token)
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect", role: .confirm) { connect() }
                            .disabled(ServerURL.normalize(address) == nil)
                    }
                }
            }
        }
    }

    private func connect() {
        guard let url = ServerURL.normalize(address) else { return }
        isConnecting = true
        error = nil
        Task {
            do {
                try await NtfyClient(baseURL: url, credential: credential).verify()
                try servers.add(url, credential: credential)
                await model.registerForPush()
                await model.importTopics(from: url)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isConnecting = false
            }
        }
    }
}
