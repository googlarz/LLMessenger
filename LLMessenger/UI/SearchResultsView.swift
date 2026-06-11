// LLMessenger/UI/SearchResultsView.swift
import SwiftUI

struct SearchResultsView: View {
    let messageResults: [MessageSearchResult]
    let briefResults: [Brief]
    let isSearching: Bool

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isSearching {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Searching…")
                            .font(Theme.sans(12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 20)
                } else if messageResults.isEmpty && briefResults.isEmpty {
                    Text("No results")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                } else {
                    if !briefResults.isEmpty {
                        SectionLabel(text: "BRIEFS")
                        ForEach(briefResults, id: \.id) { brief in
                            BriefSearchResultRow(brief: brief)
                                .onTapGesture { selectBrief(brief) }
                        }
                    }
                    if !messageResults.isEmpty {
                        SectionLabel(text: "MESSAGES")
                        ForEach(messageResults, id: \.messageRowId) { result in
                            MessageSearchResultRow(result: result)
                                .onTapGesture { openConversation(result) }
                        }
                    }
                }
            }
        }
    }

    private func selectBrief(_ brief: Brief) {
        guard let id = brief.id else { return }
        appState.selectedBriefID = id
        appState.markAsOpen(briefID: id)
        Task { try? await chatViewModel.loadBrief(brief) }
    }

    private func openConversation(_ result: MessageSearchResult) {
        guard let briefID = result.briefID,
              let brief = appState.briefs.first(where: { $0.id == briefID }) else { return }
        selectBrief(brief)
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        HStack {
            WireLabel(text)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 3)
    }
}

private struct BriefSearchResultRow: View {
    let brief: Brief
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                Text(brief.createdAt, style: .date)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(brief.notificationText)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.clear)
        .contentShape(Rectangle())
    }
}

private struct MessageSearchResultRow: View {
    let result: MessageSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ServiceStamp(service: result.service, size: 16)
                if let name = result.conversationName {
                    Text(name)
                        .font(Theme.sans(11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(result.timestamp, style: .relative)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }
            // Strip << >> highlight markers for plain display
            Text(plainSnippet)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.clear)
        .contentShape(Rectangle())
    }

    private var plainSnippet: String {
        result.snippet
            .replacingOccurrences(of: "<<", with: "")
            .replacingOccurrences(of: ">>", with: "")
    }
}
