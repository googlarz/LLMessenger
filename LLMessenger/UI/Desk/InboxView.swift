// LLMessenger/UI/Desk/InboxView.swift
//
// "What needs my attention right now?" — merges urgent messages,
// agent-proposed actions, and context suggestions into one place.

import SwiftUI

struct InboxView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    private var urgentCards: [(brief: Brief, cards: [BriefCard])] {
        let cal = Calendar.current
        return appState.briefs
            .filter { cal.isDateInToday($0.createdAt) && $0.archivedAt == nil }
            .compactMap { brief -> (Brief, [BriefCard])? in
                guard let json = BriefJSON.decodeLenient(from: brief.openingSummary) else { return nil }
                let urgent = json.cards.filter { $0.priority == "high" }
                return urgent.isEmpty ? nil : (brief, urgent)
            }
    }

    /// Agent proposals shown here exclude "maybe" items — those live in the persistent
    /// ToDoStrip's Maybe bucket, so the Inbox stays the confident "ready to send" queue.
    private var readyActions: [AgentAction] {
        appState.agentActions.filter { !$0.isMaybe }
    }

    private var hasContent: Bool {
        !readyActions.isEmpty ||
        !urgentCards.isEmpty ||
        !appState.contextSuggestions.isEmpty
    }

    var body: some View {
        if hasContent {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Agent actions first (most actionable)
                    if !readyActions.isEmpty {
                        agentActionsSection
                    }
                    // Context suggestions
                    if let suggestion = appState.contextSuggestions.first {
                        suggestionCard(suggestion)
                        Rule()
                    }
                    // Urgent messages
                    ForEach(urgentCards, id: \.brief.id) { item in
                        briefSection(item.brief, cards: item.cards)
                    }
                }
                .padding(.bottom, 24)
            }
        } else {
            emptyState
        }
    }

    // MARK: - Agent actions section

    private var agentActionsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                WireLabel("Ready to send", color: Theme.standby)
                Spacer()
                if readyActions.contains(where: { $0.riskEnum == .low }) {
                    Button("APPROVE LOW-RISK") {
                        appState.batchApproveLowRisk()
                    }
                    .buttonStyle(WireActionStyle())
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 10)
            .background(Theme.surfaceHigh.opacity(0.5))

            ForEach(readyActions) { action in
                Rule()
                ActionRow(action: action)
            }
            Rule()
        }
    }

    // MARK: - Context suggestion card

    private func suggestionCard(_ suggestion: ContextSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ServiceStamp(service: suggestion.service, size: 18)
                Text(suggestion.conversationName.uppercased())
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                WireLabel("Learned", color: Theme.standby)
            }

            Text(suggestion.rationale)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                inlineButton("Accept") { appState.acceptContextSuggestion(suggestion) }
                inlineButton("Dismiss") { appState.dismissContextSuggestion(suggestion) }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
    }

    // MARK: - Brief section (urgent cards)

    private func briefSection(_ brief: Brief, cards: [BriefCard]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                let contexts = contextMap(for: brief)
                BriefCardView(
                    number: index + 1,
                    card: card,
                    briefID: brief.id,
                    conversationContext: contexts["\(card.service)|\(card.conversationId)"],
                    onShowTimeline: { _, _, _ in appState.selectedBriefID = brief.id }
                )
                Rule()
            }
        }
    }

    private func contextMap(for brief: Brief) -> [String: ConversationContext] {
        guard let json = BriefJSON.decodeLenient(from: brief.openingSummary) else { return [:] }
        var map: [String: ConversationContext] = [:]
        for card in json.cards {
            let key = "\(card.service)|\(card.conversationId)"
            if let ctx = appState.fetchConversationContext(service: card.service, conversationId: card.conversationId) {
                map[key] = ctx
            }
        }
        return map
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            WireLabel("Inbox")
            Text("You're all caught up")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)

            if appState.briefs.isEmpty {
                Text("Your first brief will appear here soon.")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            } else {
                let total = latestBriefCardCount
                VStack(spacing: 4) {
                    Text(total > 0
                         ? "\(total) thread\(total == 1 ? "" : "s") in the latest brief"
                         : "No messages in the latest brief")
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.textTertiary)

                    if appState.heldBackCount > 0 {
                        Text("\(appState.heldBackCount) low-priority message\(appState.heldBackCount == 1 ? "" : "s") filtered")
                            .font(Theme.sans(11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .multilineTextAlignment(.center)

                // Tap the brief if there is one
                if let brief = appState.briefs.sorted(by: { $0.createdAt > $1.createdAt }).first {
                    ReadBriefLink(briefID: brief.id)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .background(Theme.sidebar)
    }

    private var latestBriefCardCount: Int {
        guard let latest = appState.briefs.sorted(by: { $0.createdAt > $1.createdAt }).first,
              let json = BriefJSON.decodeLenient(from: latest.openingSummary) else { return 0 }
        return json.cards.count
    }

    // MARK: - Helpers

    private func inlineButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(WireActionStyle())
    }
}

private struct ReadBriefLink: View {
    let briefID: Int64?
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    var body: some View {
        Button {
            appState.selectedBriefID = briefID
        } label: {
            Text("Read latest brief →")
                .font(Theme.sans(12.5))
                .foregroundStyle(isHovered ? Theme.textPrimary : Theme.textSecondary)
                .underline(isHovered)
        }
        .buttonStyle(.plain)
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
