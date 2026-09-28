import SwiftUI
import SwiftData
import NtfyKit

enum FeedMode: String {
    case list, day
}

/// Messages as a day-grouped list or as a calendar day, with a toolbar toggle shared by every feed.
struct MessageFeed<Empty: View>: View {
    let messages: [StoredMessage]
    let showsTopic: Bool
    @ViewBuilder let empty: () -> Empty
    @AppStorage("feedMode") private var mode = FeedMode.list

    var body: some View {
        Group {
            switch mode {
            case .list:
                ListFeed(messages: messages, showsTopic: showsTopic)
                    .overlay { if messages.isEmpty { empty() } }
            case .day:
                DayFeed(messages: messages, showsTopic: showsTopic)
            }
        }
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(mode == .list ? "Day View" : "List View", systemImage: mode == .list ? "calendar.day.timeline.left" : "list.bullet") {
                    withAnimation { mode = mode == .list ? .day : .list }
                }
            }
        }
    }
}

private struct ListFeed: View {
    let messages: [StoredMessage]
    let showsTopic: Bool

    private var days: [(day: Date, messages: [StoredMessage])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: messages) { calendar.startOfDay(for: $0.time) }
        return grouped.keys.sorted(by: >).map { day in (day, grouped[day]!.sorted { $0.time > $1.time }) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                ForEach(days, id: \.day) { day in
                    Section {
                        ForEach(day.messages) { stored in
                            FeedCard(stored: stored, showsTopic: showsTopic)
                        }
                    } header: {
                        Text(dayTitle(day.day))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
    }
}

/// A message card with its topic above it in cross-topic feeds, plus copy and delete actions.
private struct FeedCard: View {
    let stored: StoredMessage
    let showsTopic: Bool
    @Environment(\.modelContext) private var context

    var body: some View {
        if let message = stored.message, let subscription = stored.subscription {
            VStack(alignment: .leading, spacing: 6) {
                if showsTopic {
                    TopicLabel(subscription: subscription)
                }
                MessageCard(message: message, isUnread: !stored.isRead, tint: subscription.tint, server: subscription.serverURL)
            }
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.message }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    SpotlightIndex.remove(keys: [stored.key])
                    context.delete(stored)
                }
            }
        }
    }
}

private struct TopicLabel: View {
    let subscription: Subscription

    var body: some View {
        HStack(spacing: 6) {
            TopicIcon(symbol: subscription.symbol, tint: subscription.tint, size: 18)
            Text(subscription.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }
}

// MARK: - Search

/// Messages from every topic whose title, body, tags or attachment name contain the query, newest first.
struct SearchResults: View {
    let query: String
    @Query private var results: [StoredMessage]

    init(query: String) {
        self.query = query
        _results = Query(filter: #Predicate<StoredMessage> { $0.searchText.localizedStandardContains(query) }, sort: \.time, order: .reverse)
    }

    var body: some View {
        ListFeed(messages: results.filter { $0.subscription != nil }, showsTopic: true)
            .background(Color(.systemGroupedBackground))
            .overlay {
                if results.isEmpty { ContentUnavailableView.search(text: query) }
            }
    }
}

// MARK: - Day view

/// The day view of every topic's messages, shown on the home screen in calendar mode.
struct CalendarHome: View {
    @Query(sort: \StoredMessage.time, order: .reverse) private var messages: [StoredMessage]

    var body: some View {
        DayFeed(messages: messages.filter { $0.subscription != nil }, showsTopic: true)
            .background(Color(.systemGroupedBackground))
    }
}

private struct DayFeed: View {
    let messages: [StoredMessage]
    let showsTopic: Bool
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var opened: StoredMessage?

    private var calendar: Calendar { .current }

    private var daysWithMessages: Set<Date> {
        Set(messages.map { calendar.startOfDay(for: $0.time) })
    }

    private var dayMessages: [StoredMessage] {
        messages.filter { calendar.isDate($0.time, inSameDayAs: selectedDay) }.sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(spacing: 0) {
            WeekStrip(selectedDay: $selectedDay, marked: daysWithMessages)
            Divider()
            HourGrid(day: selectedDay, messages: dayMessages, showsTopic: showsTopic) { opened = $0 }
                .id(selectedDay)
        }
        .sheet(item: $opened) { stored in
            OpenedMessage(stored: stored)
        }
    }
}

/// Seven days around the selected one; chevrons page by week and a dot marks days with messages.
/// Only days within the servers' message retention are selectable, and never the future.
private struct WeekStrip: View {
    @Binding var selectedDay: Date
    let marked: Set<Date>
    @Environment(AppModel.self) private var model

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: .now) }
    private var earliest: Date { calendar.date(byAdding: .day, value: -(model.calendarHistoryDays - 1), to: today) ?? today }

    private func isSelectable(_ day: Date) -> Bool {
        day >= earliest && day <= today
    }

    private var week: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: selectedDay)?.start ?? selectedDay
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Previous Week", systemImage: "chevron.left") { shift(weeks: -1) }
                    .disabled(week.first.map { $0 <= earliest } ?? true)
                Spacer()
                Text(selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.headline)
                    .contentTransition(.numericText())
                Spacer()
                Button("Next Week", systemImage: "chevron.right") { shift(weeks: 1) }
                    .disabled(week.last.map { $0 >= today } ?? true)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            HStack(spacing: 0) {
                ForEach(week, id: \.self) { day in
                    let selectable = isSelectable(day)
                    DayCell(day: day, isSelected: calendar.isDate(day, inSameDayAs: selectedDay), hasMessages: marked.contains(day), isEnabled: selectable)
                        .onTapGesture { if selectable { withAnimation(.snappy) { selectedDay = day } } }
                }
            }
            if !calendar.isDateInToday(selectedDay) {
                Button("Today") { withAnimation(.snappy) { selectedDay = calendar.startOfDay(for: .now) } }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func shift(weeks: Int) {
        guard let day = calendar.date(byAdding: .weekOfYear, value: weeks, to: selectedDay) else { return }
        withAnimation(.snappy) { selectedDay = min(max(day, earliest), today) }
    }
}

private struct DayCell: View {
    let day: Date
    let isSelected: Bool
    let hasMessages: Bool
    let isEnabled: Bool

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        VStack(spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(day.formatted(.dateTime.day()))
                .font(.callout.weight(isSelected || isToday ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : Color.primary)
                .frame(width: 34, height: 34)
                .background { if isSelected { Circle().fill(isToday ? Color.accentColor : Color.primary) } }
            Circle()
                .fill(hasMessages ? Color.accentColor : .clear)
                .frame(width: 5, height: 5)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.3)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(isEnabled ? (isSelected ? [.isButton, .isSelected] : .isButton) : [])
    }
}

/// The hours of a day, each row growing to fit its messages. Today stops at the current hour,
/// which ends with a "now" marker.
private struct HourGrid: View {
    let day: Date
    let messages: [StoredMessage]
    let showsTopic: Bool
    let open: (StoredMessage) -> Void

    private var calendar: Calendar { .current }

    private var byHour: [Int: [StoredMessage]] {
        Dictionary(grouping: messages) { calendar.component(.hour, from: $0.time) }
    }

    private var lastHour: Int {
        calendar.isDateInToday(day) ? calendar.component(.hour, from: .now) : 23
    }

    private var initialHour: Int {
        if calendar.isDateInToday(day) { return max(calendar.component(.hour, from: .now) - 1, 0) }
        return messages.first.map { calendar.component(.hour, from: $0.time) } ?? 8
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if messages.isEmpty {
                        Text("No notifications on this day")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                    ForEach(0...lastHour, id: \.self) { hour in
                        HourRow(hour: hour, day: day, messages: byHour[hour] ?? [], showsTopic: showsTopic, open: open)
                            .id(hour)
                    }
                }
                .padding(.bottom, 24)
            }
            .onAppear { proxy.scrollTo(initialHour, anchor: .top) }
        }
    }
}

private struct HourRow: View {
    let hour: Int
    let day: Date
    let messages: [StoredMessage]
    let showsTopic: Bool
    let open: (StoredMessage) -> Void

    private var label: String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        return date.formatted(.dateTime.hour())
    }

    /// Index before which the "now" marker goes, when now falls within this hour of today.
    private var nowIndex: Int? {
        let calendar = Calendar.current
        let now = Date.now
        guard calendar.isDate(now, inSameDayAs: day), calendar.component(.hour, from: now) == hour else { return nil }
        return messages.firstIndex { $0.time > now } ?? messages.count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .offset(y: -7)
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(.separator).frame(height: 0.5)
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, stored in
                    if index == nowIndex { NowMarker() }
                    TimelineEntry(stored: stored, showsTopic: showsTopic)
                        .onTapGesture { open(stored) }
                }
                if nowIndex == messages.count { NowMarker() }
            }
        }
        .frame(minHeight: 48, alignment: .top)
        .padding(.horizontal)
    }
}

private struct NowMarker: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Rectangle().fill(.red).frame(height: 1.5)
        }
        .accessibilityLabel("Now")
    }
}

private struct TimelineEntry: View {
    let stored: StoredMessage

    let showsTopic: Bool

    var body: some View {
        if let message = stored.message, let subscription = stored.subscription {
            let tint = subscription.tint.color
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(stored.time, format: .dateTime.hour().minute())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if showsTopic {
                            Text(subscription.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(tint)
                        }
                        if message.effectivePriority >= .high {
                            Image(systemName: message.effectivePriority == .max ? "exclamationmark.2" : "exclamationmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(message.effectivePriority == .max ? Color.red : Color.orange)
                                .accessibilityLabel(message.effectivePriority == .max ? "Urgent" : "High priority")
                        }
                        Spacer(minLength: 0)
                        if !stored.isRead {
                            Circle().fill(tint).frame(width: 6, height: 6)
                        }
                    }
                    Text(headline(message))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if message.title?.isEmpty == false {
                        Text(NotificationFormatter.bodyText(message))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }

    private func headline(_ message: Message) -> String {
        let emoji = message.emojiTags.joined()
        let text = message.title.flatMap { $0.isEmpty ? nil : $0 } ?? NotificationFormatter.bodyText(message)
        return emoji.isEmpty ? text : "\(emoji) \(text)"
    }
}

struct OpenedMessage: View {
    let stored: StoredMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let message = stored.message, let subscription = stored.subscription {
                    MessageCard(message: message, isUnread: false, tint: subscription.tint, server: subscription.serverURL)
                        .padding()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(stored.subscription?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { stored.isRead = true }
    }
}

/// "Today", "Yesterday", the weekday within the last week, or the date.
func dayTitle(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return String(localized: "Today") }
    if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
    if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
        return date.formatted(.dateTime.weekday(.wide))
    }
    return date.formatted(date: .abbreviated, time: .omitted)
}

// MARK: - All notifications

struct AllNotificationsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \StoredMessage.time, order: .reverse) private var messages: [StoredMessage]
    @Query private var subscriptions: [Subscription]

    var body: some View {
        MessageFeed(messages: messages.filter { $0.subscription != nil }, showsTopic: true) {
            ContentUnavailableView("No Notifications", systemImage: "tray", description: Text("Messages from all your topics show up here."))
        }
        .navigationTitle("All Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshAll() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark All Read", systemImage: "checkmark.circle") {
                    Task {
                        for subscription in subscriptions where subscription.unreadCount > 0 {
                            await model.markRead(subscription)
                        }
                    }
                }
                .disabled(!subscriptions.contains { $0.unreadCount > 0 })
            }
        }
    }
}
