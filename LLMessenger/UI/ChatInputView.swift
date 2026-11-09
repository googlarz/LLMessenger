// LLMessenger/UI/ChatInputView.swift
import SwiftUI

struct ChatInputView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var appState: AppState
    @FocusState private var isFocused: Bool
    @State private var showMentionPicker = false
    @State private var mentionQuery = ""
    // Range of "@<query>" inside inputText that the picker is currently completing.
    @State private var mentionRange: Range<String.Index>?

    var body: some View {
        if DemoSeeder.isActive {
            HStack(spacing: 10) {
                Theme.standby.frame(width: 2, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
                Text("Example data — not your messages. Connect your accounts to digest your real conversations.")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                Button("SET UP MY ACCOUNTS") { appState.onExitDemo?() }
                    .buttonStyle(WireActionStyle(tint: Theme.textPrimary))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
            .background(Theme.sidebar)
        } else if !appState.isLLMConfigured {
            HStack(spacing: 10) {
                Theme.standby.frame(width: 2, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
                Text("No AI backend configured — digests and replies are paused.")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textPrimary)
                Button("OPEN SETTINGS") { appState.onOpenSettings?() }
                    .buttonStyle(WireActionStyle(tint: Theme.textPrimary))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
            .background(Theme.sidebar)
        } else {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 10) {
                // Question field — asks about your messages; it never sends to anyone.
                ZStack(alignment: .topLeading) {
                    if chatViewModel.inputText.isEmpty {
                        Text(placeholder)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $chatViewModel.inputText)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 36, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($isFocused)
                        .tint(Theme.textPrimary)
                        .accessibilityLabel("Ask about your messages")
                        .onChange(of: chatViewModel.inputText) { _, newValue in
                            updateMentionState(for: newValue)
                        }
                        .popover(isPresented: $showMentionPicker, arrowEdge: .bottom) {
                            MentionPickerView(
                                searchQuery: mentionQuery,
                                onSelect: { target in
                                    applyMention(target)
                                },
                                onDismiss: { showMentionPicker = false }
                            )
                            .padding(.vertical, 4)
                        }
                }

                // "Ask", in words — an arrow-up circle reads as "send a message".
                Button("Ask") { askIfPossible() }
                    .buttonStyle(PaperButtonStyle(prominent: canAsk))
                    .disabled(!canAsk)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Ask about your messages (⌘↩). Nothing is sent to anyone.")
                    .accessibilityLabel("Ask about your messages")
                    .accessibilityHint("Press Command Return to ask. Nothing is sent to anyone.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(Theme.sidebar)
        } // end else
    }

    private var placeholder: String {
        "Ask about your messages — type @ to write to someone"
    }

    private var canAsk: Bool {
        !chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chatViewModel.isLoading
    }

    private func askIfPossible() {
        guard canAsk else { return }
        Task {
            await chatViewModel.send()
        }
    }

    /// Detects an active `@<query>` token at or before the end of the input and
    /// shows the mention picker if found.
    private func updateMentionState(for text: String) {
        // Find the last "@" — picker opens on the most recent mention attempt.
        guard let atIndex = text.lastIndex(of: "@") else {
            showMentionPicker = false
            mentionRange = nil
            return
        }
        // The "@" must be at start or preceded by whitespace, to avoid matching emails.
        if atIndex > text.startIndex {
            let prev = text[text.index(before: atIndex)]
            if !prev.isWhitespace && !prev.isNewline {
                showMentionPicker = false
                mentionRange = nil
                return
            }
        }
        // Everything after @ up to a whitespace or end of string is the query.
        let queryStart = text.index(after: atIndex)
        let queryEnd: String.Index
        if let space = text[queryStart...].firstIndex(where: { $0.isWhitespace || $0.isNewline }) {
            queryEnd = space
        } else {
            queryEnd = text.endIndex
        }
        mentionQuery = String(text[queryStart..<queryEnd])
        mentionRange = atIndex..<queryEnd
        showMentionPicker = true
    }

    private func applyMention(_ target: ChatViewModel.MentionTarget) {
        // Writing to a person happens in the Reply composer, not here: drop the
        // typed "@query" from the question and open the composer for them.
        if let range = mentionRange {
            chatViewModel.inputText.removeSubrange(range)
        }
        showMentionPicker = false
        mentionRange = nil
        mentionQuery = ""
        chatViewModel.openComposer(for: target)
    }
}
