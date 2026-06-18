// LLMessenger/UI/Desk/ActivityView.swift
//
// "What happened today?" — chronological triage events plus open commitments.

import SwiftUI
import GRDB

struct ActivityView: View {
    @EnvironmentObject var appState: AppState
    @State private var events: [TriageEvent] = []
    @State private var expandedEventID: Int64? = nil
    @State private var displayNames: [String: String] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Open commitments (if any)
                if !appState.commitments.isEmpty {
                    commitmentsSection
                }

                // Triage events
                if events.isEmpty && appState.commitments.isEmpty {
                    emptyState
                } else if !events.isEmpty {
                    if !appState.commitments.isEmpty {
                        sectionHeader("Today's events")
                    }
                    ForEach(events) { event in
                        eventRow(event)
                        Rule()
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.sidebar)
        .task { await loadEvents() }
        .onChange(of: appState.briefs.count) { _ in Task { await loadEvents() } }
    }

    // MARK: - Commitments section

    private var commitmentsSection: some View {
        VStack(spacing: 0) {
            sectionHeader("Open commitments")
            ForEach(appState.commitments) { commitment in
                Rule()
                commitmentRow(commitment)
            }
            Rule()
        }
    }

    private func commitmentRow(_ c: Commitment) -> some View {
        HStack(spacing: 10) {
            // Direction indicator
            Image(systemName: c.direction == "ours" ? "arrow.up.right" : "arrow.down.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(c.direction == "ours" ? Theme.standby : Theme.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(c.what)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary.opacity(0.88))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let due = c.dueAt {
                    Text(relativeDue(due))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
    }

    // MARK: - Section header

    private func sectionHeader(_ label: String) -> some View {
        HStack {
            WireLabel(label)
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
        .background(Theme.surfaceHigh.opacity(0.4))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(Theme.textTertiary.opacity(0.5))
                .padding(.bottom, 4)
            Text("All quiet")
                .font(Theme.display(19))
                .foregroundStyle(Theme.textSecondary)
            Text("Triage events and commitments\nappear here as they happen.")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 64)
    }

    // MARK: - Event row

    private func eventRow(_ event: TriageEvent) -> some View {
        ActivityEventRow(
            event: event,
            displayName: displayNames["\(event.service)|\(event.conversationId)"],
            isExpanded: expandedEventID == event.id,
            onTap: {
                withAnimation(Theme.spring) {
                    expandedEventID = (expandedEventID == event.id) ? nil : event.id
                }
            }
        )
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

    private func relativeDue(_ date: Date) -> String {
        let diff = date.timeIntervalSinceNow
        if diff < 0 { return "overdue" }
        let days = Int(diff / 86400)
        if days == 0 { return "due today" }
        if days == 1 { return "due tomorrow" }
        return "due in \(days)d"
    }
}

// MARK: - Event row (extracted for hover state)

private struct ActivityEventRow: View {
    let event: TriageEvent
    let displayName: String?
    let isExpanded: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                (event.priority == "high" ? Theme.signal : Color.clear)
                    .frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(timeString(event.createdAt))
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textTertiary)

                        ServiceStamp(service: event.service, size: 16)

                        Text((displayName ?? event.conversationId).uppercased())
                            .font(Theme.mono(11, weight: .semibold))
                            .tracking(0.9)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)

                        Spacer()

                        if event.needsReply {
                            WireLabel("Reply?", color: Theme.standby)
                        }

                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }

                    if isExpanded {
                        Text(event.reason)
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.textPrimary.opacity(0.88))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 10)
            .padding(.trailing, Theme.gutter)
        }
        .background(isHovered ? Theme.surface.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
        .animation(Theme.quick, value: isHovered)
        .animation(Theme.spring, value: isExpanded)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
