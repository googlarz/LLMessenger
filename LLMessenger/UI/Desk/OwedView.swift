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
            Image(systemName: "envelope.open")
                .font(Theme.sans(28, weight: .thin))
                .foregroundStyle(Theme.textTertiary.opacity(0.5))
                .padding(.bottom, 4)
            WireLabel("Waiting")
            Text("All replied")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Text("Nobody's waiting on you.")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    // MARK: - Row

    @State private var hoveredReplyID: String? = nil

    private func replyRow(_ reply: OwedReply) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ServiceStamp(service: reply.service, size: 18)

                Text(reply.conversationName.uppercased())
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                Spacer()

                Text("\(reply.ageDays(now: Date()))d")
                    .font(Theme.mono(11))
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
                        if appState.selectedBrief == nil, let id = appState.briefs.first?.id {
                            appState.selectedBriefID = id
                        }
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
        .background(hoveredReplyID == reply.id ? Theme.surface.opacity(0.5) : Color.clear)
        .onHover { h in hoveredReplyID = h ? reply.id : nil }
        .animation(Theme.quick, value: hoveredReplyID)
    }

    /// never_draft privacy override hides the reply-draft affordance for this conversation.
    private func isDraftingDisabled(_ reply: OwedReply) -> Bool {
        appState.fetchConversationContext(service: reply.service, conversationId: reply.conversationId)?
            .privacyOverride == "never_draft"
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(WireActionStyle())
    }
}
