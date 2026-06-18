// LLMessenger/UI/ContactProfileView.swift
import SwiftUI

struct ContactProfileView: View {
    let service: String
    let conversationId: String
    let displayName: String
    @EnvironmentObject var appState: AppState
    @State private var profile: ContactProfile?
    @State private var recentCards: [BriefCard] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 10) {
                    ServiceStamp(service: service, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(Theme.display(17))
                            .foregroundStyle(Theme.textPrimary)
                        Text(Theme.serviceName(service))
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Rule()

                // Notes
                if let notes = profile?.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        WireLabel("Notes")
                        Text(notes)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }

                // Pending ask
                if let ask = profile?.pendingAsk, !ask.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        WireLabel("Pending", color: Theme.standby)
                        Text(ask)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }

                // Recent brief cards
                if !recentCards.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        WireLabel("Recent mentions")
                        ForEach(recentCards, id: \.id) { card in
                            ContactBriefCardRow(card: card)
                        }
                    }
                }
            }
            .padding()
        }
        .task { await loadProfile() }
    }

    private func loadProfile() async {
        profile = appState.contactDirectory.loadProfile(service: service, conversationId: conversationId)
        recentCards = await loadRecentCards()
    }

    private func loadRecentCards() async -> [BriefCard] {
        let allBriefs = (try? appState.repository.fetchAllBriefs()) ?? []
        var cards: [BriefCard] = []
        for brief in allBriefs {
            guard let json = BriefJSON.decodeLenient(from: brief.openingSummary) else { continue }
            let matching = json.cards.filter {
                $0.service == service && $0.conversationId == conversationId
            }
            cards.append(contentsOf: matching)
            if cards.count >= 5 { break }
        }
        return Array(cards.prefix(5))
    }
}

// MARK: - Compact card row

private struct ContactBriefCardRow: View {
    let card: BriefCard

    var body: some View {
        HStack(spacing: 8) {
            Text(card.headline)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.border, lineWidth: Theme.hairline)
        )
    }
}
