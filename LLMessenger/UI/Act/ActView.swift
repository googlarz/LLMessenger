// LLMessenger/UI/Act/ActView.swift
//
// The Act surface — the agent's pending proposals, ranked. Each row is an
// AgentAction the user can Approve, Edit, or Skip. Approving routes through the
// existing confirmed-send path (user-initiated). No auto-send.

import SwiftUI

struct ActView: View {
    @EnvironmentObject var appState: AppState

    private var hasLowRisk: Bool {
        appState.agentActions.contains { $0.riskEnum == .low }
    }

    var body: some View {
        VStack(spacing: 0) {
            commandBar
            Rule()
            if appState.agentActions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if hasLowRisk {
                            batchBar
                        }
                        Rule()
                        ForEach(appState.agentActions) { action in
                            ActionRow(action: action)
                            Rule()
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Theme.bg)
    }

    // MARK: - Command bar (P5)

    @ViewBuilder
    private var commandBar: some View {
        #if canImport(Speech)
        CommandBar(speech: SpeechInput())
        #endif
    }

    // MARK: - Batch bar

    private var batchBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Approve all low-risk") { appState.batchApproveLowRisk() }
                .buttonStyle(WireActionStyle(tint: Theme.textSecondary))
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(Theme.sans(32, weight: .thin))
                .foregroundStyle(Theme.textTertiary.opacity(0.5))
                .padding(.bottom, 4)
            WireLabel("Act")
            Text("Queue clear")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Text("No proposed actions right now.")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
