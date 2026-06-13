// LLMessenger/UI/Desk/OwedView.swift
//
// "Who's waiting on you?" — conversations where the latest inbound message is
// still unanswered and warrants a reply.

import SwiftUI

struct OwedView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        if appState.owedReplies.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    Rule()
                    ForEach(appState.owedReplies) { reply in
                        replyRow(reply)
                        Rule()
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            WireLabel("Owed")
            Text("Nobody's waiting on you")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Text("all clear")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: - Row

    private func replyRow(_ reply: OwedReply) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ServiceStamp(service: reply.service, size: 18)

                Text(reply.conversationName.uppercased())
                    .font(Theme.mono(10, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                Spacer()

                Text("\(reply.ageDays(now: Date()))d")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)

                WireLabel(reply.reason, color: Theme.standby)
            }

            Text(reply.triggerText)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary.opacity(0.88))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if !isDraftingDisabled(reply) {
                    actionButton("Reply") {
                        chatViewModel.prepareReply(
                            service: reply.service,
                            conversationID: reply.conversationId,
                            displayName: reply.conversationName
                        )
                    }
                }
                actionButton("Snooze") {
                    OwedReplyStore.snooze(reply.id, until: Date().addingTimeInterval(86400))
                    appState.reloadOwedReplies()
                }
                actionButton("Dismiss") {
                    OwedReplyStore.dismiss(reply.id)
                    appState.reloadOwedReplies()
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
    }

    /// never_draft privacy override hides the reply-draft affordance for this conversation.
    private func isDraftingDisabled(_ reply: OwedReply) -> Bool {
        appState.fetchConversationContext(service: reply.service, conversationId: reply.conversationId)?
            .privacyOverride == "never_draft"
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Theme.mono(9.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .fill(Theme.surfaceHigh)
                )
        }
        .buttonStyle(.plain)
    }
}
