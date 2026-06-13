// LLMessenger/UI/Desk/TodayView.swift
//
// Chronological feed of today's triage events.

import SwiftUI
import GRDB

struct TodayView: View {
    @EnvironmentObject var appState: AppState
    @State private var events: [TriageEvent] = []
    @State private var expandedEventID: Int64? = nil

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
            WireLabel("Today")
            Text("No triage events yet")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Text("Events will appear here as messages arrive.")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
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
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textTertiary)

                        ServiceStamp(service: event.service, size: 18)

                        Text(event.conversationId.uppercased())
                            .font(Theme.mono(10, weight: .semibold))
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
        let fetched: [TriageEvent] = (try? await db.read { d in
            let start = Calendar.current.startOfDay(for: Date())
            return try TriageEvent
                .filter(Column("createdAt") >= start)
                .order(Column("createdAt").desc)
                .fetchAll(d)
        }) ?? []
        events = fetched
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
