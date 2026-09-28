import SwiftUI
import SwiftData
import NtfyKit

struct TopicView: View {
    let subscription: Subscription
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var isComposing = false
    @State private var isEditing = false
    @State private var isAddingDevice = false

    var body: some View {
        MessageFeed(messages: subscription.messages, showsTopic: false) {
            EmptyTopicView(subscription: subscription)
        }
        .navigationTitle(subscription.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(subscription) }
        .task { await model.markRead(subscription) }
        .onChange(of: subscription.messages.count) {
            Task { await model.markRead(subscription) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Send Message", systemImage: "square.and.pencil") { isComposing = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Edit Topic", systemImage: "pencil") { isEditing = true }
                    Button("Add Device Key", systemImage: "key") { isAddingDevice = true }
                    Button(subscription.isMuted ? "Unmute" : "Mute", systemImage: subscription.isMuted ? "bell" : "bell.slash") {
                        Task { await model.setMuted(subscription, !subscription.isMuted) }
                    }
                    ShareLink(item: subscription.serverURL.appending(path: subscription.topic)) {
                        Label("Share Topic URL", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $isComposing) { ComposeView(subscription: subscription) }
        .sheet(isPresented: $isEditing) { EditTopicView(subscription: subscription) }
        .sheet(isPresented: $isAddingDevice) { DeviceKeyView(subscription: subscription) }
    }
}

private struct EmptyTopicView: View {
    let subscription: Subscription

    private var command: String {
        "curl -d \"Hello 👋\" \(subscription.serverURL.appending(path: subscription.topic).absoluteString)"
    }

    var body: some View {
        ContentUnavailableView {
            Label("No Messages", systemImage: "tray")
        } description: {
            VStack(spacing: 12) {
                Text("Publish to this topic and messages show up here.")
                Text(command)
                    .font(.caption.monospaced())
                    .padding(10)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        } actions: {
            Button("Copy Command", systemImage: "doc.on.doc") { UIPasteboard.general.string = command }
        }
    }
}
