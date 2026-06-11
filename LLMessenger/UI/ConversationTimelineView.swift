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
                SourceGlyphView(service: service, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(Theme.serviceName(service))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.surfaceHigh)

            Divider().background(Theme.border)

            if isLoading {
                Spacer()
                ProgressView()
                    .padding()
                Spacer()
            } else if entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No history found for this conversation")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            TimelineEntryRow(entry: entry)
                            if index < entries.count - 1 {
                                Divider()
                                    .background(Theme.border.opacity(0.5))
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
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                priorityBadge(entry.card.priority)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }

            // Headline
            Text(entry.card.headline)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Collapsible: summary + actions
            if expanded {
                Text(entry.card.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(actionItems, id: \.self) { action in
                            HStack(spacing: 6) {
                                Image(systemName: "circle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.accent)
                                Text(action)
                                    .font(.system(size: 12, weight: .medium))
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
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                expanded.toggle()
            }
        }
    }

    private func priorityBadge(_ priority: String) -> some View {
        let (label, color): (String, Color) = switch priority {
        case "high": ("Action needed", Color(red: 0.95, green: 0.45, blue: 0.25))
        case "med":  ("Heads-up",      Color(red: 0.90, green: 0.72, blue: 0.30))
        default:     ("FYI",           Theme.textTertiary)
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private func dateStr(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }
}
