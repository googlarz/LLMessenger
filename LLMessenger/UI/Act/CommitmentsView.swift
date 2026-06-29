// LLMessenger/UI/Act/CommitmentsView.swift
//
// The commitments ledger — promises in both directions. "You owe" (i_owe) and
// "They owe" (they_owe), each a row with the service, conversation, the promise,
// due/age, and Mark done / Drop / Draft follow-up.

import SwiftUI

struct CommitmentsView: View {
    @EnvironmentObject var appState: AppState

    private var youOwe: [Commitment] {
        appState.commitments.filter { $0.directionEnum == .iOwe }
    }
    private var theyOwe: [Commitment] {
        appState.commitments.filter { $0.directionEnum == .theyOwe }
    }

    var body: some View {
        if appState.commitments.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !youOwe.isEmpty {
                        section("You owe", commitments: youOwe)
                    }
                    if !theyOwe.isEmpty {
                        section("They owe", commitments: theyOwe)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
        }
    }

    // MARK: - Section

    private func section(_ title: String, commitments: [Commitment]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WireLabel(title)
                Spacer()
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 14)
            .padding(.bottom, 6)
            Rule()
            ForEach(commitments) { commitment in
                commitmentRow(commitment)
                Rule()
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(Theme.sans(28, weight: .thin))
                .foregroundStyle(Theme.textTertiary.opacity(0.5))
                .padding(.bottom, 4)
            WireLabel("Commitments")
            Text("All square")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Text("Nothing promised, nothing owed.")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: - Row

    @State private var hoveredCommitmentID: Int64? = nil

    private func commitmentRow(_ commitment: Commitment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ServiceStamp(service: commitment.service, size: 18)

                Text(commitment.conversationName.uppercased())
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                Spacer()

                dueLabel(commitment)
            }

            Text(commitment.what)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary.opacity(0.88))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                actionButton("Mark done") { appState.markCommitmentFulfilled(commitment) }
                actionButton("Drop") { appState.dropCommitment(commitment) }
                if isDue(commitment) {
                    actionButton("Draft follow-up") { appState.draftFollowUp(for: commitment) }
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .background(hoveredCommitmentID == commitment.id ? Theme.surface.opacity(0.5) : Color.clear)
        .onHover { h in hoveredCommitmentID = h ? commitment.id : nil }
        .animation(Theme.quick, value: hoveredCommitmentID)
    }

    private func isDue(_ commitment: Commitment) -> Bool {
        AgentEngine.isDue(commitment, now: Date())
    }

    @ViewBuilder
    private func dueLabel(_ commitment: Commitment) -> some View {
        if let dueAt = commitment.dueAt {
            let overdue = dueAt <= Date()
            WireLabel(overdue ? "overdue" : "due \(Self.dayFormatter.string(from: dueAt))",
                      color: overdue ? Theme.signal : Theme.standby)
        } else {
            let days = max(0, Int(Date().timeIntervalSince(commitment.createdAt) / 86400))
            Text("\(days)d")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(WireActionStyle())
    }
}
