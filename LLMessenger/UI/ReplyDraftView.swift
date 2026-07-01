// LLMessenger/UI/ReplyDraftView.swift
import SwiftUI
import AppKit

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
                    WireLabel(draft.senderName.isEmpty ? "Draft reply" : "Draft reply · \(draft.senderName)")
                    Spacer()
                    Button { chatViewModel.discardDraft(id: draftID) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(discardHovered ? Theme.textSecondary : Theme.textTertiary)
                            .frame(minWidth: 22, minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Discard draft")
                    .help("Discard this draft")
                    .buttonStyle(.plain)
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
                        Text(draft.conversationID.uppercased())
                            .font(Theme.mono(11))
                            .tracking(0.6)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }

                if let provenance = draft.provenance, !provenance.isEmpty {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "checkmark.shield")
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
                    WireLabel("Nothing has been sent")
                    Spacer()
                    Button("Discard") { chatViewModel.discardDraft(id: draftID) }
                        .buttonStyle(WireActionStyle())

                    Button("Open App") { openTargetApp() }
                        .buttonStyle(WireActionStyle())
                        .disabled(!canOpenTargetApp)
                        .help("Open the target app to review and send")

                    Button("Copy") { copyDraft() }
                        .buttonStyle(PaperButtonStyle(prominent: true))
                        .help("Copy the draft to the clipboard")
                }
            }

            Spacer(minLength: 28)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 9)
    }

    private var canOpenTargetApp: Bool {
        targetURL != nil
    }

    private var targetURL: URL? {
        switch draft.serviceID {
        case "telegram":
            return URL(string: "tg://")
        case "signal":
            return URL(string: "sgnl://")
        case "imessage":
            // conversationID format from iMessage adapter: "any;-;+491234567890"
            // Extract the phone/email portion after the last ";-;"
            let convID = draft.conversationID
            if let range = convID.range(of: ";-;") {
                let recipient = String(convID[range.upperBound...])
                if !recipient.isEmpty,
                   let encoded = recipient.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    return URL(string: "imessage://\(encoded)")
                }
            }
            return URL(string: "imessage://")
        default:
            return nil
        }
    }

    private func copyDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft.text, forType: .string)
    }

    private func openTargetApp() {
        guard let targetURL else { return }
        NSWorkspace.shared.open(targetURL)
    }
}
