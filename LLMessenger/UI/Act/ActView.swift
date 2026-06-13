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
            .background(Theme.bg)
        }
    }

    // MARK: - Batch bar

    private var batchBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                appState.batchApproveLowRisk()
            } label: {
                Text("APPROVE ALL LOW-RISK")
                    .font(Theme.mono(9.5, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.controlRadius)
                            .fill(Theme.surfaceHigh)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            WireLabel("Act")
            Text("Nothing to do — you're clear")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Text("no proposed actions")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
