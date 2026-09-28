import SwiftUI
import NtfyKit

struct RecentMessagesView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.entries) { entry in
                    NavigationLink {
                        MessageDetailView(entry: entry)
                    } label: {
                        MessageRow(entry: entry)
                    }
                }
                if let error = store.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("Alai")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.refresh() }
                    }
                    .disabled(store.isRefreshing || !store.hasConfiguration)
                }
            }
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView(
                        "No Messages",
                        systemImage: "bell",
                        description: Text(store.hasConfiguration ? "Messages from the last day appear here." : "Open Alai on your iPhone to set up the watch.")
                    )
                }
            }
            .task { await store.refresh() }
        }
    }
}

private struct MessageRow: View {
    let entry: RecentSnapshot.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.symbol)
                    .foregroundStyle(TopicStyle.color(entry.tint))
                Text(entry.topicTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.message.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let title = heading {
                Text(title).font(.headline).lineLimit(1)
            }
            Text(NotificationFormatter.bodyText(entry.message))
                .font(.footnote)
                .lineLimit(3)
        }
    }

    private var heading: String? {
        let text = [entry.message.emojiTags.joined(), entry.message.title ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

private struct MessageDetailView: View {
    let entry: RecentSnapshot.Entry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let title = entry.message.title, !title.isEmpty {
                    Text(entry.message.emojiTags.joined() + " " + title).font(.headline)
                }
                Text(NotificationFormatter.bodyText(entry.message))
                if !entry.message.textTags.isEmpty {
                    Text(entry.message.textTags.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                }
                Text(entry.message.date, format: .dateTime.weekday().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(entry.topicTitle)
    }
}
