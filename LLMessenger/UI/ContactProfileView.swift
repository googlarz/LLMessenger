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
                    SourceGlyphView(service: service, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(Theme.serviceName(service))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Divider()

                // Notes
                if let notes = profile?.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(notes)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }

                // Pending ask
                if let ask = profile?.pendingAsk, !ask.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pending")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(ask)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }

                // Recent brief cards
                if !recentCards.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent mentions")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
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
            guard let summary = brief.openingSummary,
                  let data = summary.data(using: .utf8),
                  let json = try? JSONDecoder().decode(BriefJSON.self, from: data) else { continue }
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
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Theme.surfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
