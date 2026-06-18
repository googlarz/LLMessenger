// LLMessenger/UI/Desk/TodayView.swift
//
// Chronological feed of today's triage events.

import SwiftUI
import GRDB

struct TodayView: View {
    @EnvironmentObject var appState: AppState
    @State private var events: [TriageEvent] = []
    @State private var expandedEventID: Int64? = nil
    @State private var displayNames: [String: String] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if events.isEmpty {
                    emptyState
                } else {
                    ForEach(events) { event in
                        eventRow(event)
                        Rule()
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .task { await loadEvents() }
        .onChange(of: appState.briefs.count) { _ in
            Task { await loadEvents() }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(Theme.sans(28, weight: .thin))
                .foregroundStyle(Theme.textTertiary.opacity(0.5))
                .padding(.bottom, 4)
            WireLabel("Today")
            Text("Nothing yet today")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Text("Events appear here as messages arrive.")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Event row

    private func eventRow(_ event: TriageEvent) -> some View {
        let isExpanded = expandedEventID == event.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Margin rule for priority
                (event.priority == "high" ? Theme.signal : Color.clear)
                    .frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(timeString(event.createdAt))
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textTertiary)

                        ServiceStamp(service: event.service, size: 18)

                        Text((displayNames["\(event.service)|\(event.conversationId)"] ?? event.conversationId).uppercased())
                            .font(Theme.mono(11, weight: .semibold))
                            .tracking(0.9)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)

                        Spacer()

                        PriorityStamp(priority: event.priority)

                        if event.needsReply {
                            WireLabel("Reply", color: Theme.standby)
                        }

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }

                    if isExpanded {
                        Text(event.reason)
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary.opacity(0.88))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)

                        WireLabel("via \(event.triggeredBy)", color: Theme.textTertiary)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 12)
            .padding(.trailing, Theme.gutter)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Theme.spring) {
                    expandedEventID = isExpanded ? nil : event.id
                }
            }
        }
    }

    // MARK: - Load

    private func loadEvents() async {
        let db = appState.database.dbQueue
        let result: ([TriageEvent], [String: String]) = (try? await db.read { d in
            let start = Calendar.current.startOfDay(for: Date())
            let fetched = try TriageEvent
                .filter(Column("createdAt") >= start)
                .order(Column("createdAt").desc)
                .fetchAll(d)
            var names: [String: String] = [:]
            for event in fetched {
                let key = "\(event.service)|\(event.conversationId)"
                guard names[key] == nil else { continue }
                let row = try Row.fetchOne(d,
                    sql: "SELECT conversationName FROM messages WHERE service = ? AND conversationId = ? AND conversationName IS NOT NULL ORDER BY timestamp DESC LIMIT 1",
                    arguments: [event.service, event.conversationId])
                if let name = row?["conversationName"] as? String { names[key] = name }
            }
            return (fetched, names)
        }) ?? ([], [:])
        events = result.0
        displayNames = result.1
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
