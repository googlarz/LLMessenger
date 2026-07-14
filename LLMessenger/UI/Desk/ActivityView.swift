// LLMessenger/UI/Desk/ActivityView.swift
//
// "What happened today?" — a retrospective summary and chronological audit.

import SwiftUI
import GRDB

struct ActivityView: View {
    @EnvironmentObject var appState: AppState
    @State private var events: [TriageEvent] = []
    @State private var audits: [ActionAuditRecord] = []
    @State private var expandedEventID: Int64? = nil
    @State private var displayNames: [String: String] = [:]
    /// Days the user has manually expanded, beyond the always-open "today".
    @State private var expandedDays: Set<Date> = []

    /// How far back the trend goes — long enough to show a real pattern
    /// (matches the weekly recap's own 7-day window plus a second week),
    /// short enough that this stays a local SQLite read, not a full scan.
    private static let windowDays = 14

    private var dayGroups: [(day: Date, events: [TriageEvent])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: events) { cal.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            (day: day, events: grouped[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                WeeklyRecapView(
                    briefs: appState.briefs,
                    cardsByBriefID: appState.briefCardsByBriefID,
                    owedCount: appState.owedCount,
                    commitmentsCount: appState.commitmentsCount
                )
                Rule()

                // What the agent actually sent for you — the "what did it do?" answer.
                if !audits.isEmpty {
                    sentSection
                }

                // Triage events, grouped by day so the trend across the window is
                // visible — not just today. Today always shows its rows; older
                // days collapse to a header + "N needed you" count and expand on
                // tap, so two weeks of history doesn't become a wall of rows.
                if events.isEmpty && audits.isEmpty {
                    emptyState
                } else if !events.isEmpty {
                    if !audits.isEmpty {
                        sectionHeader("Recent activity")
                    }
                    VStack(spacing: 0) {
                        ForEach(dayGroups, id: \.day) { group in
                            dayGroupView(group)
                        }
                    }
                    .padding(.vertical, 14)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.sidebar)
        .task { await loadEvents() }
        .onChange(of: appState.briefs.count) { Task { await loadEvents() } }
    }

    // MARK: - Day group

    private func dayGroupView(_ group: (day: Date, events: [TriageEvent])) -> some View {
        let isToday = Calendar.current.isDateInToday(group.day)
        let isExpanded = isToday || expandedDays.contains(group.day)
        let mattered = group.events.filter { $0.priority == "high" || $0.needsReply }.count

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !isToday else { return }
                withAnimation(Theme.spring) {
                    if expandedDays.contains(group.day) { expandedDays.remove(group.day) }
                    else { expandedDays.insert(group.day) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(dayLabel(group.day))
                        .font(Theme.labelFont)
                        .tracking(Theme.labelTracking)
                        .foregroundStyle(Theme.textTertiary)
                    // Only nonzero counts get a badge — a clear day should read
                    // as quiet, not compete visually with a day that had 5.
                    if mattered > 0 {
                        Text("\(mattered) NEEDED YOU")
                            .font(Theme.wireMeta)
                            .tracking(Theme.wireMetaTracking)
                            .foregroundStyle(Theme.signal)
                    }
                    Spacer()
                    if !isToday {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isToday)
            .accessibilityLabel("\(dayLabel(group.day))\(mattered > 0 ? ", \(mattered) needed you" : "")")
            .accessibilityAddTraits(isToday ? [] : .isButton)
            .accessibilityHint(isToday ? "" : (isExpanded ? "Collapse this day" : "Expand this day"))

            if isExpanded {
                VStack(spacing: 18) {
                    ForEach(group.events) { event in
                        eventRow(event)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .padding(.bottom, isExpanded ? 8 : 0)
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return Theme.dayMonthFormatter.string(from: day).uppercased()
    }

    // MARK: - Sent-on-your-behalf section

    private var sentSection: some View {
        VStack(spacing: 0) {
            sectionHeader("Sent on your behalf")
            VStack(spacing: 16) {
                ForEach(audits, id: \.id) { audit in
                    sentRow(audit)
                }
            }
            .padding(.vertical, 14)
            Rule()
        }
    }

    private func sentRow(_ a: ActionAuditRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Primary anchor: what happened, in the same serif voice as digest
            // headlines — one clear thing to read per row, not four lines of
            // equal weight.
            Text(a.detail)
                .font(Theme.display(14))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Metadata demoted to one quiet line beneath it.
            HStack(spacing: 6) {
                Text(timeString(a.createdAt))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
                ServiceStamp(service: a.service, size: 14)
                Text(displayNames["\(a.service)|\(a.conversationId)"] ?? a.conversationId)
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // "Auto-sent" = the agent sent it under a delegated lane; "By you" = you approved it.
                WireLabel(a.trigger == "delegated" ? "Auto-sent" : "By you",
                          color: a.trigger == "delegated" ? Theme.standby : Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(a.trigger == "delegated" ? "Auto-sent" : "Sent by you") to \(displayNames["\(a.service)|\(a.conversationId)"] ?? a.conversationId): \(a.detail)")
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
            // Scoped to the same window this view actually queries (14 days) —
            // an unscoped claim next to the weekly recap's own numbers read as
            // the app disagreeing with itself.
            Text("Nothing logged recently")
                .font(Theme.display(19))
                .foregroundStyle(Theme.textSecondary)
            Text("Sends and triage events\nappear here as they happen.")
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
        let start = Calendar.current.date(byAdding: .day, value: -Self.windowDays, to: Date())!
        let result: ([TriageEvent], [ActionAuditRecord], [String: String]) = (try? await db.read { d in
            let fetched = try TriageEvent
                .filter(Column("createdAt") >= start)
                .order(Column("createdAt").desc)
                .fetchAll(d)
            let auditRows = try ActionAuditRecord
                .filter(Column("createdAt") >= start)
                .order(Column("createdAt").desc)
                .fetchAll(d)
            var names: [String: String] = [:]
            let pairs = fetched.map { ($0.service, $0.conversationId) }
                + auditRows.map { ($0.service, $0.conversationId) }
            for (service, convId) in pairs {
                let key = "\(service)|\(convId)"
                guard names[key] == nil else { continue }
                let row = try Row.fetchOne(d,
                    sql: "SELECT conversationName FROM messages WHERE service = ? AND conversationId = ? AND conversationName IS NOT NULL ORDER BY timestamp DESC LIMIT 1",
                    arguments: [service, convId])
                if let name = row?["conversationName"] as? String { names[key] = name }
            }
            return (fetched, auditRows, names)
        }) ?? ([], [], [:])
        events = result.0
        audits = result.1
        displayNames = result.2
    }

    private func timeString(_ date: Date) -> String {
        Theme.timeFormatter.string(from: date)
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
        HStack(alignment: .top, spacing: 10) {
            (event.priority == "high" ? Theme.signal : Color.clear)
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))

            VStack(alignment: .leading, spacing: 4) {
                // Primary anchor: who this is about, in the same serif voice
                // used everywhere else a conversation is the headline.
                HStack(spacing: 8) {
                    Text(displayName ?? event.conversationId)
                        .font(Theme.display(14))
                        .foregroundStyle(Theme.textPrimary)
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

                // Metadata demoted to one quiet line beneath the anchor.
                HStack(spacing: 6) {
                    Text(timeString(event.createdAt))
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textTertiary)
                    ServiceStamp(service: event.service, size: 14)
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
        .padding(.vertical, 6)
        .padding(.trailing, Theme.gutter)
        .background(isHovered ? Theme.surface.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
        .animation(Theme.quick, value: isHovered)
        .animation(Theme.spring, value: isExpanded)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")
    }

    private func timeString(_ date: Date) -> String {
        Theme.timeFormatter.string(from: date)
    }
}
