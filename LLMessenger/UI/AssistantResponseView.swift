// LLMessenger/UI/AssistantResponseView.swift
//
// Q&A thread items. The assistant speaks as "the desk" — quiet paper rule,
// mono attribution, no urgency colour (answers aren't urgent). Sources are
// typeset as citations; the send confirmation is the app's central trust
// moment and gets the most deliberate treatment.

import SwiftUI

// MARK: - Conversation picker (service disambiguation)

struct ConversationPickerView: View {
    let pickerID: UUID
    let originalRequest: String
    let options: [ConversationOption]

    @EnvironmentObject var chatViewModel: ChatViewModel

    /// Prefer the human-readable display name; fall back to the service name only
    /// when displayName is missing or identical to the opaque conversationId.
    private func primaryLabel(for opt: ConversationOption) -> String {
        let name = opt.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name != opt.convId {
            return name
        }
        return Theme.serviceName(opt.service)
    }

    var body: some View {
        DeskItem(label: "Which conversation?") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(options) { opt in
                        ConversationOptionRow(
                            opt: opt,
                            label: primaryLabel(for: opt)
                        ) {
                            Task {
                                await chatViewModel.selectPickerOption(
                                    pickerID: pickerID,
                                    originalRequest: originalRequest,
                                    option: opt
                                )
                            }
                        }
                    }
                }

                Text("Tap a row, or type a name or number and press ↵")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Shared desk item scaffold

/// Left paper rule + mono label header — the visual voice of the assistant.
private struct DeskItem<Content: View>: View {
    let label: String
    var labelColor: Color = Theme.textTertiary
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Theme.textSecondary.opacity(0.5)
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    WireLabel(label, color: labelColor)
                    if let trailing { trailing }
                    Spacer(minLength: 0)
                }
                content()
            }

            Spacer(minLength: 28)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 9)
    }
}

// MARK: - User message

struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 64)
            Text(text)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.surfaceHigh)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.border, lineWidth: Theme.hairline)
                )
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 4)
    }
}

// MARK: - Assistant response

struct AssistantResponseView: View {
    @EnvironmentObject var appState: AppState
    let text: String

    private var providerLabel: String? {
        guard let provider = appState.llmProvider else { return nil }
        return provider.isCloud ? "via \(provider.displayName)" : "on-device · \(provider.displayName)"
    }

    var body: some View {
        DeskItem(
            label: "The desk",
            trailing: providerLabel.map { label in
                AnyView(
                    Text(label.uppercased())
                        .font(Theme.mono(11))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textTertiary.opacity(0.8))
                )
            }
        ) {
            Text(text)
                .font(Theme.sans(13))
                .lineSpacing(4)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Assistant response with sources

struct AssistantResponseWithSourcesView: View {
    let text: String
    let sources: [ThreadSource]

    var body: some View {
        DeskItem(label: "The desk · sourced") {
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(Theme.sans(13))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                ServiceStamp(service: source.service, size: 14)
                                Text(source.sender.uppercased())
                                    .font(Theme.mono(11, weight: .semibold))
                                    .tracking(0.8)
                                    .foregroundStyle(Theme.textSecondary)
                                Text(source.timestamp, style: .time)
                                    .font(Theme.mono(11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Text(source.text)
                                .font(Theme.display(12.5))
                                .italic()
                                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Theme.border.frame(width: Theme.hairline)
                }
            }
        }
    }
}

// MARK: - Send confirmation (the trust moment)

struct SendConfirmationView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    let confirmationID: UUID
    let draft: ReplyDraft

    var body: some View {
        DeskItem(label: "Confirm send", labelColor: Theme.standby) {
            VStack(alignment: .leading, spacing: 9) {
                if !draft.senderName.isEmpty || !draft.conversationID.isEmpty {
                    HStack(spacing: 7) {
                        ServiceStamp(service: draft.serviceID, size: 16)
                        Text("TO \((draft.senderName.isEmpty ? draft.conversationID : draft.senderName).uppercased())")
                            .font(Theme.mono(11, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Text(draft.text)
                    .font(Theme.sans(13))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Theme.standby.opacity(0.6).frame(width: 2)
                            .clipShape(RoundedRectangle(cornerRadius: 1))
                    }

                HStack {
                    WireLabel("Nothing sends until you confirm")
                    Spacer()
                    Button("Cancel") {
                        chatViewModel.cancelSendConfirmation(id: confirmationID)
                    }
                    .buttonStyle(WireActionStyle())

                    Button("Send") {
                        Task { await chatViewModel.confirmSendDraft(id: confirmationID) }
                    }
                    .buttonStyle(PaperButtonStyle(prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }
}

private struct ConversationOptionRow: View {
    let opt: ConversationOption
    let label: String
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text("\(opt.number)")
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 14, alignment: .trailing)
                ServiceStamp(service: opt.service, size: 16)
                Text(label)
                    .font(Theme.sans(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(Theme.serviceName(opt.service).uppercased())
                    .font(Theme.mono(11))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(isHovered ? Theme.surfaceHigh : Theme.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
