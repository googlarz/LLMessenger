// LLMessenger/UI/Desk/ToDoStripView.swift
//
// The persistent "you always have something to do" strip. Pinned ABOVE the Desk tab bar
// so it survives tab switches and stays visible alongside every brief. Three buckets:
//   • Commitments — promises you owe or are owed (open, brief-independent)
//   • Tasks — action items pulled from briefs (global, incomplete)
//   • Maybe — proposals the agent isn't sure actually need action ("your call")
// Renders nothing when all three are empty, so it costs no space on a quiet desk.

import SwiftUI

struct ToDoStripView: View {
    @EnvironmentObject var appState: AppState
    @State private var contentHeight: CGFloat = 0

    /// Hard ceiling: past this the strip scrolls so it can't swallow the tab panel below.
    private let maxStripHeight: CGFloat = 248

    private var maybeActions: [AgentAction] { appState.agentActions.filter { $0.isMaybe } }
    private var hasToDo: Bool { !appState.commitments.isEmpty || !appState.tasks.isEmpty }
    private var hasContent: Bool { hasToDo || !maybeActions.isEmpty }

    var body: some View {
        if hasContent {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        if hasToDo {
                            sectionHeader("To do", color: Theme.signal)
                            ForEach(appState.commitments) { c in
                                commitmentRow(c)
                                Rule()
                            }
                            ForEach(appState.tasks, id: \.id) { t in
                                taskRow(t)
                                Rule()
                            }
                        }
                        if !maybeActions.isEmpty {
                            sectionHeader("Maybe — your call", color: Theme.standby)
                            ForEach(maybeActions) { a in
                                maybeRow(a)
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
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 9)
        .background(Theme.surfaceHigh.opacity(0.5))
    }

    private func commitmentRow(_ c: Commitment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(c.directionEnum == .iOwe ? "YOU" : "THEM")
                .font(Theme.mono(9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 36, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.what)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(c.conversationName)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            // i_owe → "DONE" (you delivered); they_owe → "GOT IT" (they delivered) — same
            // action (mark fulfilled), but the label and VoiceOver text disambiguate which.
            Button(c.directionEnum == .iOwe ? "DONE" : "GOT IT") { appState.markCommitmentFulfilled(c) }
                .buttonStyle(WireActionStyle())
                .accessibilityLabel(c.directionEnum == .iOwe
                    ? "Mark done, you delivered: \(c.what)"
                    : "Mark received, they delivered: \(c.what)")
        }
        .padding(.horizontal, Theme.gutter)
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
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("DONE") { if let id = t.id { appState.completeTask(id) } }
                .buttonStyle(WireActionStyle())
                .accessibilityLabel("Complete task: \(t.text)")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 9)
    }

    private func maybeRow(_ a: AgentAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ServiceStamp(service: a.service, size: 16)
                Text(a.conversationName)
                    .font(Theme.mono(10.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            Text(a.title)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !a.reasoning.isEmpty {
                Text(a.reasoning)
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("APPROVE") { appState.approveAction(a) }
                    .buttonStyle(WireActionStyle())
                    .accessibilityLabel("Approve and send: \(a.title)")
                Button("SKIP") { appState.skipAction(a) }
                    .buttonStyle(WireActionStyle())
                    .accessibilityLabel("Skip: \(a.title)")
                Spacer()
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
    }
}

/// Measures the strip's intrinsic content height so it can size-to-fit up to a cap.
private struct StripHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
