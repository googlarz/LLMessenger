// LLMessenger/UI/ChatInputView.swift
import SwiftUI

struct ChatInputView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var appState: AppState
    @FocusState private var isFocused: Bool
    @State private var selectedTone: String? = nil
    @State private var showMentionPicker = false
    @State private var mentionQuery = ""
    // Range of "@<query>" inside inputText that the picker is currently completing.
    @State private var mentionRange: Range<String.Index>?

    var body: some View {
        if DemoSeeder.isActive {
            HStack(spacing: 10) {
                Theme.standby.frame(width: 2, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
                Text("You're reading sample data. Connect your accounts to brief your real messages.")
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
                Text("No AI backend configured — briefs and replies are paused.")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                Button("OPEN SETTINGS") { appState.onOpenSettings?() }
                    .buttonStyle(WireActionStyle(tint: Theme.textPrimary))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
            .background(Theme.sidebar)
        } else {
        VStack(alignment: .leading, spacing: 7) {
            if let target = chatViewModel.pendingTarget {
                MentionTargetChip(target: target) {
                    chatViewModel.clearMentionTarget()
                }
            }

            HStack(spacing: 14) {
                WireLabel("Tone")
                ForEach(["Formal", "Short", "Casual"], id: \.self) { tone in
                    let selected = selectedTone == tone
                    Button {
                        withAnimation(Theme.quick) {
                            selectedTone = selected ? nil : tone
                        }
                    } label: {
                        Text(tone.uppercased())
                            .font(Theme.mono(9.5, weight: .semibold))
                            .tracking(1.0)
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                            .padding(.vertical, 2)
                            .overlay(alignment: .bottom) {
                                (selected ? Theme.textPrimary : Color.clear)
                                    .frame(height: 1.5)
                                    .offset(y: 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Input field
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

                // Send — paper on ink
                Button { sendIfPossible() } label: {
                    ZStack {
                        Circle()
                            .fill(canSend ? Theme.textPrimary : Theme.surfaceHigh)
                            .frame(width: 28, height: 28)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(canSend ? Theme.bg : Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .animation(Theme.quick, value: canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(Theme.sidebar)
        } // end else
    }

    private var placeholder: String {
        if let target = chatViewModel.pendingTarget {
            return "Reply to \(target.displayName) on \(Theme.serviceName(target.service)) — say what you want, AI drafts it"
        }
        return "Ask about this brief, or type @ to write to anyone"
    }

    private var canSend: Bool {
        !chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chatViewModel.isLoading
    }

    private var toneSuffix: String {
        switch selectedTone {
        case "Formal":  return " [Reply formally and professionally]"
        case "Short":   return " [Keep reply under 2 sentences]"
        case "Casual":  return " [Use a friendly, casual tone]"
        default:        return ""
        }
    }

    private func sendIfPossible() {
        guard canSend else { return }
        if !toneSuffix.isEmpty {
            chatViewModel.inputText += toneSuffix
        }
        selectedTone = nil
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
        HStack(spacing: 7) {
            ServiceStamp(service: target.service, size: 16)
            Text("TO \(target.displayName.uppercased())")
                .font(Theme.mono(9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textPrimary)
            if target.isGroup {
                WireLabel("Group")
            }
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Clear recipient")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius)
                .strokeBorder(Theme.border, lineWidth: Theme.hairline)
        )
    }
}
