// LLMessenger/UI/ReplyDraftView.swift
import SwiftUI

struct ReplyDraftView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    let draftID: UUID
    let draft: ReplyDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                Text("Draft reply to \(draft.senderName.isEmpty ? "conversation" : draft.senderName)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    chatViewModel.discardDraft(id: draftID)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(draft.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            HStack {
                Spacer()
                Button("Discard") {
                    chatViewModel.discardDraft(id: draftID)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button("Send Reply") {
                    Task { try? await chatViewModel.sendDraft(draft) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(draft.conversationID == "unknown")
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
