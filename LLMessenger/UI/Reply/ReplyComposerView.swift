// LLMessenger/UI/Reply/ReplyComposerView.swift
//
// A focused sheet over the main window. Chosen over an in-window panel because
// sending to a real person deserves one modal moment: the recipient, the
// service and the exact text are the only things on screen, the single-key
// queue shortcuts behind it are suspended while it is up, and ⌘Return/Esc
// mean exactly Send/Cancel.

import SwiftUI

struct ReplyComposerView: View {
    @StateObject private var model: ReplyComposerModel
    @FocusState private var editorFocused: Bool

    init(request: ReplyComposerRequest, appState: AppState) {
        _model = StateObject(wrappedValue: ReplyComposerModel(request: request, appState: appState))
    }

    private var request: ReplyComposerRequest { model.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)

            Rule()

            if !model.context.isEmpty {
                contextBlock
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                Rule()
            }

            VStack(alignment: .leading, spacing: 8) {
                editor
                draftRow
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 14)

            Rule()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 540)
        .background(Theme.bg)
        .onAppear { editorFocused = true }
        .onDisappear { model.cancel() }
    }

    // MARK: Header — who and where

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            WireLabel(request.sourceActionID == nil ? "Reply" : "Edit reply")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("To")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textTertiary)
                Text(request.displayName)
                    .font(Theme.display(19))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text("·")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textTertiary)
                Text(request.serviceName)
                    .font(Theme.sans(13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                if request.isGroup {
                    WireLabel("Group", color: Theme.textSecondary)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            if request.isGroup {
                Text("Everyone in this group will see your reply.")
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            if !request.canSend {
                // Said up front, before the user writes anything.
                HStack(alignment: .top, spacing: 8) {
                    Theme.standby.frame(width: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                    Text("LLMessenger can read \(request.serviceName) but can't send through it. "
                         + (ServiceDeepLink.opensExactChat(service: request.service, conversationId: request.conversationId)
                            ? "Your reply is copied and the chat opens in \(request.serviceName) — paste and send it there."
                            : "Your reply is copied and \(request.serviceName) opens — choose the chat, then paste."))
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("To \(request.displayName) on \(request.serviceName)\(request.isGroup ? ", group chat" : "")")
    }

    // MARK: Context — the last incoming messages, quietly

    private var contextBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            let shown = Array(model.context.suffix(3))
            ForEach(Array(shown.enumerated()), id: \.element.messageId) { index, message in
                let author = message.isSent ? "You" : message.sender
                let sameAsAbove = index > 0 && (shown[index - 1].isSent ? "You" : shown[index - 1].sender) == author
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(sameAsAbove ? "" : author)
                        .font(Theme.mono(10.5, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .frame(width: 92, alignment: .leading)
                    Text(message.text)
                        .font(Theme.display(13, weight: .regular).italic())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(Calendar.current.isDateInToday(message.timestamp)
                         ? Theme.timeFormatter.string(from: message.timestamp)
                         : Theme.dayMonthTimeFormatter.string(from: message.timestamp))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Latest messages in this conversation")
    }

    // MARK: Editor — exactly what will be sent

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if model.text.isEmpty {
                Text("Write to \(request.displayName)…")
                    .font(Theme.sans(13.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8)
                    .padding(.leading, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $model.text)
                .font(Theme.sans(13.5))
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .focused($editorFocused)
                .tint(Theme.textPrimary)
                .disabled(model.isDrafting)
                .accessibilityLabel("Message to \(request.displayName). This exact text is what will be sent.")
        }
        .frame(height: 150)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius)
                .strokeBorder(editorFocused ? Theme.textTertiary : Theme.border, lineWidth: Theme.hairline)
        )
    }

    @ViewBuilder
    private var draftRow: some View {
        HStack(spacing: 8) {
            if model.isDrafting {
                ProgressView().controlSize(.small)
                Text("Drafting…")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                if model.draftingBlockedReason == nil {
                    Button(model.draftButtonTitle) {
                        Task { await model.draftWithAI() }
                    }
                    .buttonStyle(WireActionStyle.textAction())
                    .help("Fill the text box with a suggested reply. Nothing is sent.")
                    .accessibilityHint("Fill the text box with a suggested reply. Nothing is sent.")
                }
                if model.textBeforeDraft != nil {
                    Button("Restore my text") { model.restoreTextBeforeDraft() }
                        .buttonStyle(WireActionStyle.textAction(tint: Theme.textTertiary))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, -8)
        if let reason = model.draftingBlockedReason {
            Text(reason)
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.textTertiary)
        } else if let error = model.draftError {
            Text(error)
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.standby)
        }
    }

    // MARK: Footer — the consequence, then the decision

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if request.canSend {
                    Text("You'll have 5 seconds to undo.")
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let error = model.sendError {
                    Text(error)
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.signal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button("Cancel") { model.cancel() }
                .buttonStyle(PaperButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button {
                model.submit()
            } label: {
                HStack(spacing: 8) {
                    Text(request.canSend ? "Send" : "Copy and Open \(request.serviceName)")
                    Text("⌘↩")
                        .font(Theme.mono(10.5, weight: .semibold))
                        .opacity(0.6)
                }
                .lineLimit(1)
                .fixedSize()
            }
            .buttonStyle(PaperButtonStyle(prominent: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canSubmit)
            .opacity(model.canSubmit ? 1 : 0.45)
            .accessibilityLabel(request.canSend
                ? "Send to \(request.displayName) on \(request.serviceName)"
                : "Copy the reply and open \(request.serviceName)")
            .accessibilityHint(request.canSend
                ? "Sends in 5 seconds. You can undo until then."
                : "Nothing is sent from LLMessenger.")
        }
    }
}
