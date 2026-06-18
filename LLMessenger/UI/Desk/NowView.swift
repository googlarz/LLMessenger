// LLMessenger/UI/Desk/NowView.swift
//
// "Does anything need me right now?" — high-priority or needs-reply cards from today.

import SwiftUI

struct NowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    private var urgentItems: [(brief: Brief, cards: [BriefCard])] {
        let cal = Calendar.current
        return appState.briefs
            .filter { cal.isDateInToday($0.createdAt) && $0.archivedAt == nil }
            .compactMap { brief -> (Brief, [BriefCard])? in
                guard let json = BriefJSON.decodeLenient(from: brief.openingSummary) else { return nil }
                let urgent = json.cards.filter { $0.priority == "high" }
                return urgent.isEmpty ? nil : (brief, urgent)
            }
    }

    var body: some View {
        if urgentItems.isEmpty {
            VStack(spacing: 0) {
                if let suggestion = appState.contextSuggestions.first {
                    suggestionCard(suggestion)
                }
                emptyState
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let suggestion = appState.contextSuggestions.first {
                        suggestionCard(suggestion)
                    }
                    ForEach(urgentItems, id: \.brief.id) { item in
                        briefSection(item.brief, cards: item.cards)
                    }
                }
                .padding(.bottom, 24)
            }
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
                actionButton("Accept") { appState.acceptContextSuggestion(suggestion) }
                actionButton("Dismiss") { appState.dismissContextSuggestion(suggestion) }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .background(Theme.surfaceHigh)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(WireActionStyle())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.dashed")
                .font(Theme.sans(28, weight: .thin))
                .foregroundStyle(Theme.textTertiary.opacity(0.5))
                .padding(.bottom, 4)
            WireLabel("Now")
            Text("Nothing urgent")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Text(appState.heldBackCount > 0 ? "\(appState.heldBackCount) lower-priority items held back" : "You're up to date.")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: - Brief section

    private func briefSection(_ brief: Brief, cards: [BriefCard]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule()
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                let contexts = contextMap(for: brief)
                BriefCardView(
                    number: index + 1,
                    card: card,
                    briefID: brief.id,
                    conversationContext: contexts["\(card.service)|\(card.conversationId)"],
                    onShowTimeline: { _, _, _ in }
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
}

