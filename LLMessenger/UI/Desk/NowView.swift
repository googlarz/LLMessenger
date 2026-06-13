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
                guard
                    let summary = brief.openingSummary,
                    let data = summary.data(using: .utf8),
                    let json = try? JSONDecoder().decode(BriefJSON.self, from: data)
                else { return nil }
                let urgent = json.cards.filter { $0.priority == "high" }
                return urgent.isEmpty ? nil : (brief, urgent)
            }
    }

    var body: some View {
        if urgentItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(urgentItems, id: \.brief.id) { item in
                        briefSection(item.brief, cards: item.cards)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            WireLabel("Now")
            Text("Nothing needs you")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Text("\(appState.heldBackCount) held back")
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
                    conversationContext: contexts["\(card.service):\(card.conversationId)"],
                    onShowTimeline: { _, _, _ in }
                )
                Rule()
            }
        }
    }

    private func contextMap(for brief: Brief) -> [String: ConversationContext] {
        guard
            let summary = brief.openingSummary,
            let data = summary.data(using: .utf8),
            let json = try? JSONDecoder().decode(BriefJSON.self, from: data)
        else { return [:] }
        var map: [String: ConversationContext] = [:]
        for card in json.cards {
            let key = "\(card.service):\(card.conversationId)"
            if let ctx = appState.fetchConversationContext(service: card.service, conversationId: card.conversationId) {
                map[key] = ctx
            }
        }
        return map
    }
}

