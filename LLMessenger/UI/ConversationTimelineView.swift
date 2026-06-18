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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            TimelineEntryRow(entry: entry)
                            if index < entries.count - 1 {
                                Rule(color: Theme.border.opacity(0.5))
                                    .padding(.leading, 20)
                            }
                        }
                    }
                    .padding(.vertical, 8)
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
        VStack(alignment: .leading, spacing: 8) {
            // Date + priority row
            HStack(spacing: 8) {
                Text(dateStr(entry.briefDate))
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                priorityBadge(entry.card.priority)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(Theme.sans(10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }

            // Headline
            Text(entry.card.headline)
                .font(Theme.display(14))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

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
                                    .font(Theme.sans(9))
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
        .padding(.vertical, 12)
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

    private func dateStr(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }
}
