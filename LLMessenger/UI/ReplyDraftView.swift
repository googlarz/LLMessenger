// LLMessenger/UI/ReplyDraftView.swift
import SwiftUI

struct ReplyDraftView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    let draftID: UUID
    let draft: ReplyDraft
    @State private var discardHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Theme.textSecondary.opacity(0.5)
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    WireLabel("Proposed reply")
                    Spacer()
                    Button { chatViewModel.discardDraft(id: draftID) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(discardHovered ? Theme.textSecondary : Theme.textTertiary)
                            .frame(minWidth: 22, minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Discard draft")
                    .help("Discard this draft")
                    .buttonStyle(.quiet)
                    .animation(Theme.quick, value: discardHovered)
                    .onHover { discardHovered = $0 }
                }

                if draft.conversationID == "unknown" {
                    Text("Cannot determine recipient — this digest spans multiple conversations. Discard and ask about one conversation specifically.")
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !draft.conversationID.isEmpty {
                    HStack(spacing: 7) {
                        ServiceStamp(service: draft.serviceID, size: 14)
                        Text("\(chatViewModel.displayName(for: draft)) · \(Theme.serviceName(draft.serviceID))")
                            .font(Theme.sans(12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }

                if let provenance = draft.provenance, !provenance.isEmpty {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "checkmark.shield").accessibilityHidden(true)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.ok)
                            .padding(.top, 1)
                        Text(provenance)
                            .font(Theme.sans(11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Draft source. \(provenance)")
                }

                Text(draft.text)
                    .font(Theme.sans(13))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Theme.border.frame(width: Theme.hairline)
                    }

                HStack(spacing: 4) {
                    Spacer()
                    Button("Discard") { chatViewModel.discardDraft(id: draftID) }
                        .buttonStyle(WireActionStyle())

                    Button("Review and send…") { chatViewModel.reviewAndSend(draftID: draftID) }
                        .buttonStyle(PaperButtonStyle(prominent: true))
                        .disabled(!ChatViewModel.isAddressable(draft))
                        .help("Open this text in the Reply window, where you check it and send it")
                        .accessibilityHint("Open this text in the Reply window, where you check it and send it")
                }
            }

            Spacer(minLength: 28)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 9)
    }
}
