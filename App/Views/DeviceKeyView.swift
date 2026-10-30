import SwiftUI
import NtfyKit

/// Creates an access token for a device that publishes to a topic, and shows how to use it.
struct DeviceKeyView: View {
    private enum Expiry: String, CaseIterable, Identifiable {
        case never = "Never", month = "30 days", quarter = "90 days", year = "1 year"
        var id: Self { self }
        var date: Date? {
            switch self {
            case .never: nil
            case .month: .now.addingTimeInterval(30 * 86_400)
            case .quarter: .now.addingTimeInterval(90 * 86_400)
            case .year: .now.addingTimeInterval(365 * 86_400)
            }
        }
    }

    let subscription: Subscription
    @Environment(ServerDirectory.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var expiry = Expiry.never
    @State private var token: Account.Token?
    @State private var isCreating = false
    @State private var error: String?

    private var isSignedIn: Bool { servers.credential(for: subscription.serverURL) != nil }

    private var topicURL: URL { subscription.serverURL.appending(path: subscription.topic) }

    private func command(_ token: String) -> String {
        "curl -H \"Authorization: Bearer \(token)\" -d \"Hello from \(label)\" \(topicURL.absoluteString)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isSignedIn {
                    Section {
                        Label("Sign in to \(ServerURL.shortDisplay(subscription.serverURL)) to create device keys.", systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                } else if let token {
                    Section {
                        Text(token.token)
                            .fontDesign(.monospaced)
                            .textSelection(.enabled)
                        Button("Copy Key", systemImage: "doc.on.doc") { Platform.copy(token.token) }
                    } header: {
                        Text("Key for \(label)")
                    } footer: {
                        Text("Also listed under Settings → Servers → Access Tokens, where it can be revoked.")
                    }
                    Section("Publish from the Device") {
                        Text(command(token.token))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Copy Command", systemImage: "terminal") { Platform.copy(command(token.token)) }
                        ShareLink(item: command(token.token)) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                } else {
                    Section {
                        TextField("Device name, e.g. Garage sensor", text: $label)
                        Picker("Expires", selection: $expiry) {
                            ForEach(Expiry.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } footer: {
                        Text("The key acts as your account: it can publish to and read every topic you can. Give each device its own key so it can be revoked on its own.")
                    }
                    if let error {
                        Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Device Key")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(token == nil ? "Cancel" : "Done", role: token == nil ? .cancel : .confirm) { dismiss() }
                }
                if isSignedIn, token == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if isCreating {
                            ProgressView()
                        } else {
                            Button("Create", role: .confirm) { create() }
                                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func create() {
        isCreating = true
        error = nil
        Task {
            do {
                token = try await servers.client(for: subscription.serverURL).createToken(label: label, expires: expiry.date)
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }
}

/// Access tokens on the signed-in account, with revocation.
struct AccessTokensView: View {
    let server: URL
    @Environment(ServerDirectory.self) private var servers
    @State private var tokens: [Account.Token] = []
    @State private var error: String?
    @State private var isLoading = true

    private var appToken: String? {
        if case let .token(token) = servers.credential(for: server) { token } else { nil }
    }

    var body: some View {
        List {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            ForEach(tokens) { token in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(token.label.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Unnamed"))
                            .font(.headline)
                        if token.token == appToken {
                            Text("This app").font(.caption2.bold()).foregroundStyle(.secondary)
                        }
                    }
                    Text(String(token.token.prefix(10)) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        if let used = token.lastAccessDate {
                            Label { Text(used, format: .relative(presentation: .named)) } icon: { Image(systemName: "clock") }
                        }
                        if let expires = token.expiryDate {
                            Label { Text(expires, format: .dateTime.day().month().year()) } icon: { Image(systemName: "hourglass") }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .deleteDisabled(token.token == appToken || token.provisioned == true)
            }
            .onDelete { offsets in
                let revoked = offsets.map { tokens[$0] }
                Task {
                    for token in revoked {
                        do {
                            try await servers.client(for: server).deleteToken(token.token)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    await load()
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if tokens.isEmpty, error == nil {
                ContentUnavailableView("No Access Tokens", systemImage: "key", description: Text("Create device keys from a topic's menu."))
            }
        }
        .navigationTitle("Access Tokens")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            tokens = try await servers.client(for: server).account().tokens ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
