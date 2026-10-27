import SwiftUI
import NtfyKit

struct MessageCard: View {
    let message: Message
    let isUnread: Bool
    let tint: TopicTint
    let server: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            bodyText
            if let attachment = message.attachment {
                AttachmentView(attachment: attachment, server: server)
            }
            if !message.textTags.isEmpty {
                FlowLayout {
                    ForEach(message.textTags, id: \.self, content: TagChip.init)
                }
            }
            if let actions = message.actions, !actions.isEmpty {
                HStack {
                    ForEach(actions) { action in
                        Button(action.label) {
                            Task { await ActionPerformer.perform(action) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(action.kind == .broadcast || action.kind == nil)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 18))
        .overlay(alignment: .leading) {
            if message.effectivePriority >= .high {
                UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18)
                    .fill(message.effectivePriority == .max ? Color.red : Color.orange)
                    .frame(width: 4)
            }
        }
        .contentShape(.rect(cornerRadius: 18))
        .onTapGesture {
            if let click = message.click, let url = URL(string: click) { openURL(url) }
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isUnread {
                Circle().fill(tint.color).frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            }
            let emoji = message.emojiTags.joined()
            if !emoji.isEmpty { Text(emoji) }
            if let title = message.title, !title.isEmpty {
                Text(title).font(.headline)
            }
            Spacer(minLength: 8)
            PriorityBadge(priority: message.effectivePriority)
                .labelStyle(.iconOnly)
                .font(.caption.bold())
            Text(message.date, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        let text = message.message ?? ""
        if message.encoding == "base64" {
            Text("Binary message").italic().foregroundStyle(.secondary)
        } else if message.isMarkdown, let markdown = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(markdown).textSelection(.enabled)
        } else if !text.isEmpty {
            Text(text).textSelection(.enabled)
        }
    }
}

struct AttachmentView: View {
    let attachment: Attachment
    let server: URL
    @Environment(ServerDirectory.self) private var servers
    @Environment(\.openURL) private var openURL
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if attachment.isImage, !attachment.isExpired {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: 12))
                        .frame(maxHeight: 320)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.fill.tertiary)
                        .frame(height: 160)
                        .overlay { ProgressView() }
                }
            } else {
                Button {
                    if let url = URL(string: attachment.url) { openURL(url) }
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(attachment.name).lineLimit(1)
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "doc.fill")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(attachment.isExpired)
            }
        }
        .task(id: attachment.url) { await loadImage() }
    }

    private var detail: String {
        if attachment.isExpired { return String(localized: "Expired") }
        return attachment.size.map { $0.formatted(.byteCount(style: .file)) } ?? ""
    }

    /// Loads with the server's credential, which AsyncImage cannot send.
    private func loadImage() async {
        guard attachment.isImage, !attachment.isExpired, let url = URL(string: attachment.url) else { return }
        var request = URLRequest(url: url)
        if url.host() == server.host(), let credential = servers.credential(for: server) {
            request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        if let (data, _) = try? await URLSession.shared.data(for: request) {
            image = PlatformImage(data: data)
        }
    }
}
