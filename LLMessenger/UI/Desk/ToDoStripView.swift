// LLMessenger/UI/Desk/ToDoStripView.swift
//
// Open commitments and extracted tasks shown at the top of Act. Reply proposals live in
// the action feed below so each user-level obligation appears in one place. Two buckets:
//   • Commitments — promises you owe or are owed (open, brief-independent)
//   • Tasks — action items pulled from briefs (global, incomplete)
// Renders nothing when both are empty, so it costs no space on a quiet desk.

import SwiftUI

struct ToDoStripView: View {
    @EnvironmentObject var appState: AppState
    let layout: DeskLayout
    @State private var contentHeight: CGFloat = 0

    init(layout: DeskLayout = .regular) {
        self.layout = layout
    }

    /// Hard ceiling: past this the strip scrolls so it can't swallow the tab panel below.
    private let maxStripHeight: CGFloat = 248

    private var hasToDo: Bool {
        !appState.attentionProjection.commitments.isEmpty || !appState.attentionProjection.tasks.isEmpty
    }

    var body: some View {
        if hasToDo {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        if hasToDo {
                            sectionHeader("To do", color: Theme.signal)
                            ForEach(appState.attentionProjection.commitments) { c in
                                commitmentRow(c)
                                Rule()
                            }
                            ForEach(appState.attentionProjection.tasks, id: \.id) { t in
                                taskRow(t)
                                Rule()
                            }
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: StripHeightKey.self, value: g.size.height)
                    })
                }
                // Size to content when there are few items (no reserved empty space), but cap
                // and scroll once it would crowd the tabs below. Avoids a greedy ScrollView
                // reserving 248pt for a single commitment.
                .frame(height: min(contentHeight == 0 ? maxStripHeight : contentHeight, maxStripHeight))
                .onPreferenceChange(StripHeightKey.self) { contentHeight = $0 }
                Rule()
            }
            .background(Theme.sidebar)
        }
    }

    private func sectionHeader(_ title: String, color: Color) -> some View {
        HStack {
            WireLabel(title, color: color)
            Spacer()
        }
        .padding(.horizontal, layout.gutter)
        .padding(.vertical, 9)
        .background(Theme.surfaceHigh.opacity(0.5))
    }

    private func commitmentRow(_ c: Commitment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(c.directionEnum == .iOwe ? "YOU" : "THEM")
                .font(Theme.mono(9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: layout == .compact ? 42 : 36, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.what)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(layout == .compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(c.conversationName)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer()
            Button { appState.markCommitmentFulfilled(c) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .help(c.directionEnum == .iOwe ? "Mark done" : "Mark received")
                .accessibilityLabel(c.directionEnum == .iOwe
                    ? "Mark done, you delivered: \(c.what)"
                    : "Mark received, they delivered: \(c.what)")
        }
        .padding(.horizontal, layout.gutter)
        .padding(.vertical, 9)
    }

    private func taskRow(_ t: BriefTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("—")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textTertiary)
            Text(t.text)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(layout == .compact ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer()
            Button { if let id = t.id { appState.completeTask(id) } } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .help("Mark done")
                .accessibilityLabel("Complete task: \(t.text)")
        }
        .padding(.horizontal, layout.gutter)
        .padding(.vertical, 9)
    }

}

/// Measures the strip's intrinsic content height so it can size-to-fit up to a cap.
private struct StripHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
