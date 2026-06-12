// LLMessenger/UI/Onboarding/OnboardingWindowController.swift
import AppKit
import SwiftUI

// MARK: - Window Controller

@MainActor
final class OnboardingWindowController: NSWindowController {
    var onComplete: (() -> Void)?
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = .dark
        window.backgroundColor = NSColor(Theme.bg)
        window.isReleasedWhenClosed = false
        window.level = .floating

        super.init(window: window)

        let view = OnboardingView(database: database, onComplete: { [weak self] in
            self?.close()       // close before releasing self
            self?.onComplete?() // then notify — AppDelegate nils the reference after this
        })
        window.contentView = NSHostingView(rootView: view)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Onboarding View

private struct OnboardingView: View {
    let database: AppDatabase
    let onComplete: () -> Void

    private enum Step: CaseIterable {
        case welcome, llmSetup, signalSetup, imessageSetup, telegramSetup, done

        // Steps shown as dots (excluding welcome and done)
        static var dotSteps: [Step] { [.llmSetup, .signalSetup, .imessageSetup, .telegramSetup, .done] }
    }

    @State private var currentStep: Step = .welcome
    @State private var selectedProvider: LLMProvider = .anthropic
    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    @State private var ollamaModel: String = ""
    @State private var signalEnabled: Bool = true
    @State private var signalNumber: String = ""
    @State private var imessageEnabled: Bool = true
    @State private var telegramEnabled: Bool = true
    @State private var telegramAdapter: SubprocessAdapter? = nil

    private var repo: SettingsRepository { SettingsRepository(database: database) }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Back button row
                HStack {
                    if currentStep != .welcome {
                        Button(action: goBack) {
                            Label("Back", systemImage: "chevron.left")
                                .font(Theme.sans(12.5))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .frame(height: 44)
                .padding(.horizontal, 28)

                // Step content
                Group {
                    switch currentStep {
                    case .welcome:      welcomeStep
                    case .llmSetup:     llmStep
                    case .signalSetup:  signalStep
                    case .imessageSetup: imessageStep
                    case .telegramSetup: telegramStep
                    case .done:         doneStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Progress dots
                if currentStep != .welcome {
                    progressDots
                        .padding(.bottom, 24)
                }
            }
        }
        .frame(width: 520, height: 580)
        .background(Theme.bg)
        .foregroundStyle(Theme.textPrimary)
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(Array(Step.dotSteps.enumerated()), id: \.offset) { index, step in
                Circle()
                    .fill(currentStep == step ? Theme.textPrimary : Theme.border)
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Navigation

    private func goBack() {
        switch currentStep {
        case .llmSetup:     currentStep = .welcome
        case .signalSetup:  currentStep = .llmSetup
        case .imessageSetup: currentStep = .signalSetup
        case .telegramSetup: currentStep = .imessageSetup
        case .done:          currentStep = .telegramSetup
        default: break
        }
    }

    private func advance() {
        switch currentStep {
        case .welcome:      currentStep = .llmSetup
        case .llmSetup:     currentStep = .signalSetup
        case .signalSetup:  currentStep = .imessageSetup
        case .imessageSetup: currentStep = .telegramSetup
        case .telegramSetup: currentStep = .done
        case .done:         break
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "tray.2.fill")
                .font(Theme.sans(56, weight: .thin))
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: 10) {
                Text("Welcome to LLMessenger")
                    .font(Theme.display(26))
                    .foregroundStyle(Theme.textPrimary)
                Text("Your private AI inbox assistant.\nSet up in 3 minutes.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button("Get Started") { advance() }
                .buttonStyle(PrimaryButtonStyle())

            // Demo mode is only offered on a fresh database, so seeding into
            // the live store is safe; exiting the demo wipes everything.
            if databaseIsEmpty {
                VStack(spacing: 6) {
                    Button("EXPLORE THE DEMO DESK") {
                        try? DemoSeeder.seed(into: database)
                        onComplete()
                    }
                    .buttonStyle(WireActionStyle(tint: Theme.textSecondary))
                    Text("A finished brief with sample data — nothing to connect.")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 48)
    }

    private var databaseIsEmpty: Bool {
        ((try? BriefRepository(database: database).latestBriefID()) ?? nil) == nil
    }

    // MARK: - Step 2: LLM Setup

    private var llmStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                stepHeader(title: "Choose Your AI", subtitle: nil)

                // Provider picker
                HStack(spacing: 0) {
                    ForEach(LLMProvider.allCases, id: \.self) { provider in
                        Button(provider.displayName) {
                            selectedProvider = provider
                        }
                        .buttonStyle(SegmentButtonStyle(isSelected: selectedProvider == provider))
                    }
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(Theme.border, lineWidth: Theme.hairline)
                )

                // Key / model field
                VStack(alignment: .leading, spacing: 8) {
                    switch selectedProvider {
                    case .anthropic:
                        SecureField("API Key (sk-ant-…)", text: $anthropicKey)
                            .textFieldStyle(DarkTextFieldStyle())
                    case .openai:
                        SecureField("API Key (sk-…)", text: $openAIKey)
                            .textFieldStyle(DarkTextFieldStyle())
                    case .ollama:
                        TextField("Model (e.g. llama3.1)", text: $ollamaModel)
                            .textFieldStyle(DarkTextFieldStyle())
                        Text("Requires Ollama running locally")
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if selectedProvider.requiresAPIKey {
                        Text("Your messages are processed by \(selectedProvider.displayName) to generate summaries.")
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Button("Continue") {
                    saveLLMSettings()
                    advance()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!llmValid)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 16)
        }
    }

    private var llmValid: Bool {
        switch selectedProvider {
        case .anthropic: return !anthropicKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .openai:    return !openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .ollama:    return true
        }
    }

    private func saveLLMSettings() {
        repo.saveSelectedLLMProvider(selectedProvider)
        switch selectedProvider {
        case .anthropic:
            try? repo.saveLLMKey(provider: .anthropic, key: anthropicKey)
        case .openai:
            try? repo.saveLLMKey(provider: .openai, key: openAIKey)
        case .ollama:
            let model = ollamaModel.trimmingCharacters(in: .whitespaces)
            repo.saveOllamaModel(model.isEmpty ? "llama3.1" : model)
        }
    }

    // MARK: - Step 3: Signal

    private var signalStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                serviceToggleHeader(
                    title: "Signal",
                    icon: "lock.shield.fill",
                    color: Theme.serviceSignal,
                    isEnabled: $signalEnabled
                )

                if signalEnabled {
                    VStack(spacing: 8) {
                        Text("Enter your Signal phone number. LLMessenger uses signal-cli to read messages.")
                            .font(Theme.sans(12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)

                        TextField("+1 (555) 000-0000", text: $signalNumber)
                            .textFieldStyle(DarkTextFieldStyle())
                    }
                }

                Button("Continue") {
                    if signalEnabled && !signalNumber.trimmingCharacters(in: .whitespaces).isEmpty {
                        try? repo.saveSignalAccount(signalNumber)
                    }
                    saveServiceEnabled("signal", signalEnabled)
                    advance()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(signalEnabled && signalNumber.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Step 4: iMessage

    private var imessageStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                serviceToggleHeader(
                    title: "iMessage",
                    icon: "message.fill",
                    color: Theme.serviceIMessage,
                    isEnabled: $imessageEnabled
                )

                if imessageEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        instructionRow(number: "1", text: "Open System Settings → Privacy & Security → Full Disk Access")
                        instructionRow(number: "2", text: "Click the + button and add LLMessenger")
                        instructionRow(number: "3", text: "Restart LLMessenger after granting access")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius)
                            .strokeBorder(Theme.border, lineWidth: Theme.hairline)
                    )

                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Button("Continue") {
                    saveServiceEnabled("imessage", imessageEnabled)
                    advance()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 16)
        }
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(Theme.mono(10, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
            Text(text)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 5: Telegram

    private var telegramStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                serviceToggleHeader(
                    title: "Telegram",
                    icon: "paperplane.fill",
                    color: Theme.serviceTelegram,
                    isEnabled: $telegramEnabled
                )

                if telegramEnabled {
                    if let adapter = telegramAdapter {
                        TelegramSignInView(adapter: adapter, onSuccess: {
                            saveServiceEnabled("telegram", true)
                            advance()
                        })
                        .frame(width: 360)
                    } else {
                        VStack(spacing: 12) {
                            Text("Telegram requires API credentials from my.telegram.org and the LLMessenger Telegram adapter binary.")
                                .font(Theme.sans(12.5))
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(20)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius)
                                .strokeBorder(Theme.border, lineWidth: Theme.hairline)
                        )
                    }
                }

                if !telegramEnabled || telegramAdapter == nil {
                    Button("Continue") {
                        saveServiceEnabled("telegram", telegramEnabled)
                        advance()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 16)
        }
        .onAppear { buildTelegramAdapterIfNeeded() }
    }

    private func buildTelegramAdapterIfNeeded() {
        guard telegramAdapter == nil,
              let path = telegramAdapterPath() else { return }
        let creds = SettingsRepository().loadTelegramCredentials()
        guard !creds.apiId.isEmpty && !creds.apiHash.isEmpty else { return }
        telegramAdapter = SubprocessAdapter(
            serviceID: "telegram",
            adapterPath: path,
            config: makeTelegramConfig(apiId: creds.apiId, apiHash: creds.apiHash)
        )
    }

    private func telegramAdapterPath() -> String? {
        let bundled = Bundle.main.path(forResource: "telegram-adapter", ofType: nil)
        if let p = bundled, FileManager.default.fileExists(atPath: p) { return p }
        let community = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llmessenger/adapters/telegram/telegram-adapter")
        if FileManager.default.fileExists(atPath: community.path) { return community.path }
        return nil
    }

    private func makeTelegramConfig(apiId: String, apiHash: String) -> [String: Any] {
        let sessionPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llmessenger/data/telegram/session").path
        return ["api_id": apiId, "api_hash": apiHash, "session_path": sessionPath]
    }

    // MARK: - Step 6: Done

    private var doneStep: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.sans(56, weight: .thin))
                .foregroundStyle(Theme.ok)

            VStack(spacing: 10) {
                Text("You're all set!")
                    .font(Theme.display(26))
                    .foregroundStyle(Theme.textPrimary)
                Text("LLMessenger is ready. It will check your messages\nand generate briefs automatically.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button("Start Using LLMessenger") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                onComplete()
            }
            .buttonStyle(PrimaryButtonStyle())

            Spacer()
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Helpers

    private func serviceToggleHeader(title: String, icon: String, color: Color, isEnabled: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(color.opacity(0.55), lineWidth: 1)
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(Theme.sans(20))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(Theme.display(17))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Toggle("", isOn: isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.border, lineWidth: Theme.hairline)
        )
    }

    private func saveServiceEnabled(_ service: String, _ enabled: Bool) {
        var config = ServiceConfig.default(for: service)
        config.enabled = enabled
        try? repo.saveServiceConfig(config)
    }

    private func stepHeader(title: String, subtitle: String?) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Button Styles

/// Paper on ink — onboarding's prominent action, sized up from PaperButtonStyle.
private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(13, weight: .semibold))
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(Theme.textPrimary)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(12.5, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(Theme.surface.opacity(configuration.isPressed ? 0.6 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .strokeBorder(Theme.border, lineWidth: Theme.hairline)
            )
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(12.5, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Theme.surfaceHigh : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            .padding(2)
    }
}

private struct DarkTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .foregroundStyle(Theme.textPrimary)
            .font(Theme.sans(12.5))
    }
}
