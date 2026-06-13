// LLMessenger/UI/Act/CommandBar.swift
//
// P5: a command input at the top of the Act surface. The user types a command
// ("handle the easy ones") and presses Enter, or dictates it with the mic. The
// text is classified by CommandRouter and executed against the agent queue via
// AppState.runCommand; the result is shown inline.
//
// SECURITY: only the user's typed/spoken command text is classified — message
// content never flows into the command path.

import SwiftUI

struct CommandBar<Recognizer: SpeechRecognizing>: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var speech: Recognizer
    @FocusState private var isFocused: Bool

    @State private var commandText: String = ""
    @State private var resultLine: String?
    @State private var isRunning = false
    @State private var micDenied = false

    init(speech: @autoclosure @escaping () -> Recognizer) {
        _speech = StateObject(wrappedValue: speech())
    }

    private var canRun: Bool {
        !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning
    }

    private var micAvailable: Bool {
        speech.isAvailable && !micDenied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if commandText.isEmpty {
                        Text("Tell the agent… e.g. 'handle the easy ones'")
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.textTertiary)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $commandText)
                        .textFieldStyle(.plain)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.textPrimary)
                        .focused($isFocused)
                        .onSubmit { run() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .strokeBorder(Theme.border, lineWidth: Theme.hairline)
                )

                if micAvailable {
                    micButton
                }

                runButton
            }

            if let resultLine {
                Text(resultLine)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
        .onChange(of: speech.transcript) { newValue in
            if speech.isListening { commandText = newValue }
        }
        .onChange(of: speech.isListening) { listening in
            // When dictation finishes with a transcript, run the command.
            if !listening && !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                run()
            }
        }
    }

    // MARK: - Mic

    private var micButton: some View {
        Button { toggleListening() } label: {
            ZStack {
                Circle()
                    .fill(speech.isListening ? Theme.textPrimary : Theme.surfaceHigh)
                    .frame(width: 28, height: 28)
                Image(systemName: speech.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(speech.isListening ? Theme.bg : Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .help(speech.isListening ? "Stop dictation" : "Dictate a command")
    }

    private func toggleListening() {
        if speech.isListening {
            speech.stop()
            return
        }
        Task {
            let granted = await speech.requestAuthorization()
            guard granted else {
                micDenied = true
                return
            }
            do {
                try speech.start()
            } catch {
                resultLine = "Couldn't start dictation."
            }
        }
    }

    // MARK: - Run

    private var runButton: some View {
        Button { run() } label: {
            ZStack {
                Circle()
                    .fill(canRun ? Theme.textPrimary : Theme.surfaceHigh)
                    .frame(width: 28, height: 28)
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canRun ? Theme.bg : Theme.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canRun)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Run command (⌘↩)")
    }

    private func run() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        if speech.isListening { speech.stop() }
        isRunning = true
        resultLine = nil
        Task {
            let router = CommandRouter(llmClient: appState.llmClient, llmModel: appState.llmModel)
            let parsed = await router.classify(command: text)
            let outcome = await appState.runCommand(parsed)
            await MainActor.run {
                resultLine = outcome
                commandText = ""
                isRunning = false
            }
        }
    }
}
