// LLMessenger/UI/ChatInputView.swift
import SwiftUI

struct ChatInputView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @FocusState private var isFocused: Bool
    @State private var showMentionPicker = false
    @State private var mentionQuery = ""
    // Range of "@<query>" inside inputText that the picker is currently completing.
    @State private var mentionRange: Range<String.Index>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = chatViewModel.pendingTarget {
                MentionTargetChip(target: target) {
                    chatViewModel.clearMentionTarget()
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Input field
                ZStack(alignment: .topLeading) {
                    if chatViewModel.inputText.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $chatViewModel.inputText)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 36, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($isFocused)
                        .tint(Theme.accent)
                        .onChange(of: chatViewModel.inputFocusRequest) { _ in
                            isFocused = true
                        }
                        .onChange(of: chatViewModel.inputText) { newValue in
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

                // Send button
                Button { sendIfPossible() } label: {
                    ZStack {
                        Circle()
                            .fill(canSend ? Theme.accent : Theme.surfaceHigh)
                            .frame(width: 30, height: 30)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(canSend ? .white : Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .animation(.easeInOut(duration: 0.15), value: canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    private var placeholder: String {
        chatViewModel.pendingTarget == nil
            ? "Ask about these messages… (type @ to pick a contact)"
            : "Type the message — Claude will draft it"
    }

    private var canSend: Bool {
        !chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chatViewModel.isLoading
    }

    private func sendIfPossible() {
        guard canSend else { return }
        Task { await chatViewModel.send() }
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
        // Remove the typed "@query" so the user can type the message body cleanly.
        if let range = mentionRange {
            chatViewModel.inputText.removeSubrange(range)
        }
        chatViewModel.setMentionTarget(target)
        showMentionPicker = false
        mentionRange = nil
        mentionQuery = ""
    }
}

private struct MentionTargetChip: View {
    let target: ChatViewModel.MentionTarget
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.serviceColor(target.service))
                .frame(width: 6, height: 6)
            Text("To \(target.displayName)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text("· \(Theme.serviceName(target.service))")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            if target.isGroup {
                Text("· group")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
