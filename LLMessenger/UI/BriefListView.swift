// LLMessenger/UI/BriefListView.swift
import SwiftUI

struct BriefListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        List(selection: Binding(
            get: { appState.selectedBriefID },
            set: { appState.selectedBriefID = $0 }
        )) {
            ForEach(appState.briefGroups, id: \.id) { group in
                Section(group.label) {
                    ForEach(group.briefs, id: \.id) { brief in
                        BriefRowView(brief: brief)
                            .tag(brief.id!)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: appState.selectedBriefID) { newID in
            guard let id = newID,
                  let brief = appState.briefs.first(where: { $0.id == id })
            else { return }
            Task {
                try? await chatViewModel.loadBrief(brief)
            }
        }
    }
}

private struct BriefRowView: View {
    let brief: Brief

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(brief.notificationText)
                .font(.callout)
                .lineLimit(1)
            if let summary = brief.openingSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(brief.createdAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
