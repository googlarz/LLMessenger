// LLMessenger/UI/ReplyDraftView.swift
import SwiftUI

struct ReplyDraftView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    let draftID: UUID
    let draft: ReplyDraft

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
                .cornerRadius(1)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text("Draft reply" + (draft.senderName.isEmpty ? "" : " to \(draft.senderName)"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Button { chatViewModel.discardDraft(id: draftID) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                if draft.conversationID == "unknown" {
                    Text("Cannot determine recipient — brief spans multiple conversations. Discard and ask about one conversation specifically.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                } else if !draft.conversationID.isEmpty {
                    Text("→ \(draft.serviceID) · \(draft.conversationID)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }

                Text(draft.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Spacer()
                    Button("Discard") { chatViewModel.discardDraft(id: draftID) }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .buttonStyle(.plain)

                    Button("Send Reply") {
                        Task { try? await chatViewModel.sendDraft(draft) }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(draft.conversationID == "unknown" ? Theme.surfaceHigh : Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .buttonStyle(.plain)
                    .disabled(draft.conversationID == "unknown")
                }
            }
        }
        .padding(12)
        .background(Theme.accentMuted)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.accent.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
