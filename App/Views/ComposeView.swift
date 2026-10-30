import SwiftUI
import NtfyKit

struct ComposeView: View {
    let subscription: Subscription
    @Environment(AppModel.self) private var model
    @Environment(ServerDirectory.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var priority = Priority.default
    @State private var tags = ""
    @State private var isSending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (optional)", text: $title)
                    TextField("Message", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    Picker("Priority", selection: $priority) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Tags, comma separated", text: $tags)
                        .identifierEntry()
                } footer: {
                    Text("Tags like `warning` or `tada` show as emoji.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Send to \(subscription.title)")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send", systemImage: "paperplane.fill", role: .confirm) { send() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func send() {
        isSending = true
        error = nil
        let tagList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task {
            do {
                try await servers.client(for: subscription.serverURL).publish(topic: subscription.topic, message: text, title: title, priority: priority, tags: tagList)
                await model.refresh(subscription)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isSending = false
            }
        }
    }
}
