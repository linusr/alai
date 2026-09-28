import SwiftUI
import NtfyKit

struct AddTopicView: View {
    @Environment(AppModel.self) private var model
    @Environment(ServerDirectory.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var server: URL?
    @State private var topic = ""
    @State private var displayName = ""
    @State private var symbol = "bell.fill"
    @State private var tint = TopicTint.blue
    @State private var isSubscribing = false
    @State private var reservation: TopicAccess? = .denyAll
    @State private var error: String?

    private var isSignedIn: Bool { server.map { servers.credential(for: $0) != nil } ?? false }

    private var isValid: Bool {
        topic.wholeMatch(of: /[-_A-Za-z0-9]{1,64}/) != nil && server != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let server {
                    Section {
                        NavigationLink {
                            BrowseTopicsView(server: server)
                        } label: {
                            Label("Browse Existing Topics", systemImage: "list.bullet.rectangle")
                        }
                    }
                }
                Section {
                    HStack {
                        TextField("Topic name", text: $topic)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .fontDesign(.monospaced)
                        Button("Generate", systemImage: "dice") {
                            topic = String((0..<16).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
                        }
                        .labelStyle(.iconOnly)
                    }
                    if servers.servers.count > 1 {
                        Picker("Server", selection: $server) {
                            ForEach(servers.servers, id: \.self) { url in
                                Text(ServerURL.shortDisplay(url)).tag(Optional(url))
                            }
                        }
                    }
                } footer: {
                    Text("Letters, numbers, dashes and underscores. Anyone who knows the name of an unprotected topic can publish to it.")
                }
                if isSignedIn {
                    Section {
                        Picker("Reserve", selection: $reservation) {
                            Text("Don't reserve").tag(TopicAccess?.none)
                            ForEach(TopicAccess.allCases) { Text($0.label).tag(Optional($0)) }
                        }
                    } header: {
                        Text("Access")
                    } footer: {
                        Text(reservation == nil
                             ? "Anyone who knows the name can use this topic, subject to the server's access rules."
                             : "Reserves the topic for your account. Other users get the chosen access; you and your device keys always have full access.")
                    }
                }
                Section("Appearance") {
                    TextField("Display name (optional)", text: $displayName)
                    TopicAppearancePicker(symbol: $symbol, tint: $tint)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubscribing {
                        ProgressView()
                    } else {
                        Button("Subscribe", role: .confirm) { subscribe() }
                            .disabled(!isValid)
                    }
                }
            }
            .onAppear { server = server ?? servers.defaultServer }
        }
    }

    private func subscribe() {
        guard let server else { return }
        isSubscribing = true
        error = nil
        Task {
            do {
                try await model.subscribe(server: server, topic: topic, displayName: displayName.isEmpty ? nil : displayName, symbol: symbol, tint: tint, reserve: isSignedIn ? reservation : nil)
                dismiss()
            } catch NtfyError.http(status: 409, _, _) {
                error = String(localized: "This topic is already reserved by another user.")
            } catch NtfyError.http(status: 401, _, _) {
                error = String(localized: "Your account cannot reserve topics. Choose \"Don't reserve\", or ask the server admin for a tier with reservations.")
            } catch {
                self.error = error.localizedDescription
            }
            isSubscribing = false
        }
    }
}

struct EditTopicView: View {
    @Bindable var subscription: Subscription
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: Binding(get: { subscription.displayName ?? "" }, set: { subscription.displayName = $0 }), prompt: Text(subscription.topic))
                    TopicAppearancePicker(symbol: $subscription.symbol, tint: $subscription.tint)
                }
                Section {
                    LabeledContent("Topic", value: subscription.topic)
                    LabeledContent("Server", value: ServerURL.shortDisplay(subscription.serverURL))
                }
            }
            .navigationTitle("Edit Topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
    }
}

struct TopicAppearancePicker: View {
    @Binding var symbol: String
    @Binding var tint: TopicTint

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TopicIcon(symbol: symbol, tint: tint, size: 52)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(TopicTint.allCases) { option in
                        Circle()
                            .fill(option.color.gradient)
                            .frame(width: 28, height: 28)
                            .overlay { if option == tint { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                            .onTapGesture { tint = option }
                            .accessibilityLabel(option.rawValue.capitalized)
                            .accessibilityAddTraits(option == tint ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                ForEach(Subscription.symbolChoices, id: \.self) { option in
                    Image(systemName: option)
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .foregroundStyle(option == symbol ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background(option == symbol ? tint.color : .clear, in: .rect(cornerRadius: 8))
                        .onTapGesture { symbol = option }
                        .accessibilityAddTraits(option == symbol ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 6)
    }
}
