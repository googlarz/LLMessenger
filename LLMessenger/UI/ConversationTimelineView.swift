// LLMessenger/UI/ConversationTimelineView.swift
import SwiftUI

struct ConversationTimelineView: View {
    let service: String
    let conversationId: String
    let displayName: String
    let repository: BriefRepository

    @State private var entries: [(briefDate: Date, card: BriefCardRecord)] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                ServiceStamp(service: service, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(Theme.display(15))
                        .foregroundStyle(Theme.textPrimary)
                    Text(Theme.serviceName(service))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.surface)

            Rule()

            if isLoading {
                Spacer()
                ProgressView()
                    .padding()
                Spacer()
            } else if entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(Theme.sans(28, weight: .thin))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No history found for this conversation")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    // Grouped by day, rule only under the day header — not after
                    // every entry. Entries within a day separate by whitespace
                    // (18pt between, ≤4pt inside), which is what actually reads
                    // as "these are distinct" instead of a hairline after every
                    // paragraph.
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(dayGroups, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(dayLabel(group.day))
                                    .font(Theme.labelFont)
                                    .tracking(Theme.labelTracking)
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 6)
                                Rule(color: Theme.border.opacity(0.6))
                                    .padding(.horizontal, 20)
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                                        TimelineEntryRow(entry: entry)
                                    }
                                }
                                .padding(.top, 12)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(Theme.bg)
        .task { await loadEntries() }
    }

    private func loadEntries() async {
        isLoading = true
        entries = (try? repository.fetchConversationTimeline(service: service, conversationID: conversationId)) ?? []
        isLoading = false
    }

    private var dayGroups: [(day: Date, entries: [(briefDate: Date, card: BriefCardRecord)])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: entries) { cal.startOfDay(for: $0.briefDate) }
        return grouped.keys.sorted(by: >).map { day in
            (day: day, entries: grouped[day]!.sorted { $0.briefDate > $1.briefDate })
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return Theme.dayMonthFormatter.string(from: day)
    }
}

// MARK: - Single timeline row

private struct TimelineEntryRow: View {
    let entry: (briefDate: Date, card: BriefCardRecord)
    @State private var expanded = false
    @State private var isHovered = false

    private var actionItems: [String] {
        guard let data = entry.card.actionItems.data(using: .utf8),
              let items = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Headline is the anchor — the day group header already carries the
            // date, so this row only needs to say what happened.
            HStack(alignment: .top, spacing: 8) {
                Text(entry.card.headline)
                    .font(Theme.display(14))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(Theme.sans(10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 3)
            }

            // Metadata demoted to one quiet line beneath the headline.
            HStack(spacing: 8) {
                Text(timeStr(entry.briefDate))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
                priorityBadge(entry.card.priority)
            }

            // Collapsible: summary + actions
            if expanded {
                Text(entry.card.summary)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(actionItems, id: \.self) { action in
                            HStack(spacing: 6) {
                                Image(systemName: "circle")
                                    .font(Theme.sans(10))
                                    .foregroundStyle(Theme.signal)
                                Text(action)
                                    .font(Theme.sans(12, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(isHovered ? Theme.surface.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.spring) { expanded.toggle() } }
        .onHover { isHovered = $0 }
        .animation(Theme.quick, value: isHovered)
    }

    private func priorityBadge(_ priority: String) -> some View {
        let (label, color): (String, Color) = switch priority {
        case "high": ("Action needed", Theme.signal)
        case "med":  ("Heads-up",      Theme.standby)
        default:     ("FYI",           Theme.textTertiary)
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(Theme.mono(11, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(color)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(color.opacity(0.45), lineWidth: 1)
        )
    }

    private func timeStr(_ date: Date) -> String {
        Theme.timeFormatter.string(from: date)
    }
}
