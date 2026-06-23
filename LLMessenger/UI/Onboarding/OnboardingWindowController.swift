// LLMessenger/UI/Onboarding/OnboardingWindowController.swift
import AppKit
import SwiftUI
import Combine

// MARK: - Window Controller

@MainActor
final class OnboardingWindowController: NSWindowController {
    var onComplete: (() -> Void)?
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Follow NSApp.appearance (set from saved theme in AppDelegate).
        window.backgroundColor = NSColor(Theme.bg)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: window)

        let view = OnboardingView(database: database, onComplete: { [weak self] in
            self?.close()
            self?.onComplete?()
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

    private enum Step { case services, aiSetup, prepareSync, syncing }

    @State private var step: Step = .services

    // Services
    @State private var imessageEnabled   = true
    @State private var imessageGranted   = false
    @State private var signalEnabled     = false
    @State private var signalNumber      = ""
    @State private var signalDaemonUp    = false
    @State private var telegramEnabled   = false
    @State private var telegramConnected = false
    @State private var telegramApiId     = ""
    @State private var telegramApiHash   = ""
    @State private var telegramAdapter: SubprocessAdapter?

    // AI
    @State private var selectedProvider: LLMProvider = AppleFM.isAvailable ? .appleIntelligence : .anthropic
    @State private var anthropicKey = ""
    @State private var openAIKey    = ""
    @State private var ollamaModel  = ""
    @State private var backHovered = false
    @State private var demoLinkHovered = false
    @State private var telegramApiLinkHovered = false
    @State private var signalSetupLinkHovered = false

    // Syncing tips
    @State private var tipIndex = 0
    @State private var firstBriefReady = false
    private let tips = [
        "Your first daily digest will be ready in a few minutes.",
        "Open the menu bar icon any time — it updates whenever new messages arrive.",
        "LLMessenger proposes replies in your voice — you approve each one before anything is sent.",
        "The Desk shows everything that needs your attention today.",
        "LLMessenger learns your tone and the people you talk to over time.",
        "The Act tab queues draft replies and follow-ups. Approve, edit, or skip — you're always in control."
    ]

    private var repo: SettingsRepository { SettingsRepository(database: database) }

    var body: some View {
        VStack(spacing: 0) {
            // Back row
            HStack {
                if step == .aiSetup || step == .prepareSync {
                    Button(action: goBack) {
                        Label("Back", systemImage: "chevron.left")
                            .font(Theme.sans(12.5))
                            .foregroundStyle(backHovered ? Theme.textPrimary : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .animation(Theme.quick, value: backHovered)
                    .onHover { backHovered = $0 }
                }
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 28)

            // Content
            Group {
                switch step {
                case .services:    servicesStep
                case .aiSetup:     aiStep
                case .prepareSync: prepareSyncStep
                case .syncing:     syncingStep
                }
            }
            .id(step.hashValue)
            .transition(.opacity)
            .animation(Theme.quick, value: step.hashValue)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Dots
            HStack(spacing: 8) {
                ForEach([Step.services, .aiSetup, .prepareSync, .syncing], id: \.hashValue) { s in
                    Circle()
                        .fill(step == s ? Theme.textPrimary : Theme.border)
                        .frame(width: 6, height: 6)
                        .animation(Theme.quick, value: step)
                }
            }
            .padding(.bottom, 24)
        }
        .frame(width: 520, height: 600)
        .background(Theme.bg)
        .foregroundStyle(Theme.textPrimary)
    }

    // MARK: - Navigation

    private func goBack() {
        withAnimation(Theme.quick) {
            switch step {
            case .aiSetup:     step = .services
            case .prepareSync: step = .aiSetup
            default: break
            }
        }
    }

    // MARK: - Step 1: Services

    private var servicesStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                stepHeader(
                    title: "Connect your messages",
                    subtitle: "LLMessenger reads your messages, writes a daily digest, and highlights what needs your reply — all on this Mac. Choose where to read from."
                )

                serviceRow(title: "iMessage", icon: "message.fill",
                           color: Theme.serviceIMessage, isEnabled: $imessageEnabled) {
                    imessageInline
                }

                serviceRow(title: "Telegram", icon: "paperplane.fill",
                           color: Theme.serviceTelegram, isEnabled: $telegramEnabled) {
                    telegramInline
                }

                serviceRow(title: "Signal", icon: "lock.shield.fill",
                           color: Theme.serviceSignal, isEnabled: $signalEnabled) {
                    signalInline
                }

                VStack(spacing: 10) {
                    Button("Continue") {
                        saveAllServices()
                        withAnimation(Theme.quick) { step = .aiSetup }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!servicesReady)

                    if databaseIsEmpty {
                        Button("Explore the demo instead") {
                            try? DemoSeeder.seed(into: database)
                            onComplete()
                        }
                        .buttonStyle(.plain)
                        .font(Theme.sans(12))
                        .foregroundStyle(demoLinkHovered ? Theme.textSecondary : Theme.textTertiary)
                        .animation(Theme.quick, value: demoLinkHovered)
                        .onHover { demoLinkHovered = $0 }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .onAppear {
            imessageGranted = Self.checkFullDiskAccess()
            buildTelegramAdapterIfNeeded()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            guard step == .services, !imessageGranted else { return }
            imessageGranted = Self.checkFullDiskAccess()
        }
    }

    private var servicesReady: Bool {
        guard imessageEnabled || telegramEnabled || signalEnabled else { return false }
        if telegramEnabled && !telegramConnected { return false }
        if signalEnabled && signalNumber.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    @ViewBuilder private var imessageInline: some View {
        if imessageGranted {
            statusPill(icon: "checkmark.circle.fill", text: "Full Disk Access granted", color: Theme.ok)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                instructionRow(n: "1", text: "Open System Settings → Privacy & Security → Full Disk Access")
                instructionRow(n: "2", text: "Click + and add LLMessenger")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()

            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .buttonStyle(PaperButtonStyle())
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var telegramInline: some View {
        if telegramConnected {
            statusPill(icon: "checkmark.circle.fill", text: "Telegram connected", color: Theme.ok)
        } else if let adapter = telegramAdapter {
            TelegramSignInView(adapter: adapter, onSuccess: {
                telegramConnected = true
                saveServiceEnabled("telegram", true)
            })
        } else {
            VStack(spacing: 10) {
                HStack {
                    Text("You need a free API key from Telegram.")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Get API keys →") {
                        NSWorkspace.shared.open(URL(string: "https://my.telegram.org/apps")!)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.sans(12, weight: .semibold))
                    .foregroundStyle(telegramApiLinkHovered ? Theme.textSecondary : Theme.textPrimary)
                    .animation(Theme.quick, value: telegramApiLinkHovered)
                    .onHover { telegramApiLinkHovered = $0 }
                }

                credRow(label: "API ID",   placeholder: "12345678",  text: $telegramApiId, secure: false)
                credRow(label: "API Hash", placeholder: "0abc123…",  text: $telegramApiHash, secure: true)

                Button("Connect Telegram") { connectTelegram() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(telegramApiId.trimmingCharacters(in: .whitespaces).isEmpty ||
                              telegramApiHash.trimmingCharacters(in: .whitespaces).isEmpty ||
                              telegramAdapterPath() == nil)
                    .frame(maxWidth: .infinity)
            }
            .padding(14)
            .surfaceCard()
        }
    }

    @ViewBuilder private var signalInline: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("+1 (555) 000-0000", text: $signalNumber)
                .textFieldStyle(DarkTextFieldStyle())
                .onChange(of: signalEnabled) { if $0 { checkSignalDaemon() } }

            if signalEnabled {
                if signalDaemonUp {
                    statusPill(icon: "checkmark.circle.fill", text: "signal-mcp detected", color: Theme.ok)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(Theme.sans(11))
                        Text("signal-mcp not detected.")
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.textTertiary)
                        Button("Setup guide →") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/googlarz/signal-mcp")!)
                        }
                        .buttonStyle(.plain)
                        .font(Theme.sans(11, weight: .semibold))
                        .foregroundStyle(signalSetupLinkHovered ? Theme.textSecondary : Theme.textTertiary)
                        .animation(Theme.quick, value: signalSetupLinkHovered)
                        .onHover { signalSetupLinkHovered = $0 }
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            guard step == .services, signalEnabled else { return }
            checkSignalDaemon()
        }
    }

    private func checkSignalDaemon() {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:7583/api/v1/rpc")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.5
        req.httpBody = Data("{\"jsonrpc\":\"2.0\",\"method\":\"listAccounts\",\"id\":1}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async {
                signalDaemonUp = (resp as? HTTPURLResponse).map { $0.statusCode < 500 } ?? false
            }
        }.resume()
    }

    // MARK: - Step 2: AI

    private var aiStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                stepHeader(title: "Choose your AI", subtitle: nil)

                // Provider picker
                HStack(spacing: 0) {
                    ForEach(LLMProvider.availableCases, id: \.self) { provider in
                        Button(provider.displayName) { selectedProvider = provider }
                            .buttonStyle(SegmentButtonStyle(isSelected: selectedProvider == provider))
                    }
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: Theme.hairline))

                VStack(alignment: .leading, spacing: 8) {
                    switch selectedProvider {
                    case .appleIntelligence:
                        HStack(spacing: 8) {
                            Image(systemName: "lock.laptopcomputer").foregroundStyle(Theme.ok)
                            Text("Runs entirely on this Mac. No account, no API key — your messages never leave your computer.")
                                .font(Theme.sans(12))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .surfaceCard()
                    case .anthropic:
                        SecureField("API Key (sk-ant-…)", text: $anthropicKey)
                            .textFieldStyle(DarkTextFieldStyle())
                    case .openai:
                        SecureField("API Key (sk-…)", text: $openAIKey)
                            .textFieldStyle(DarkTextFieldStyle())
                    case .ollama:
                        TextField("Model (e.g. llama3.1)", text: $ollamaModel)
                            .textFieldStyle(DarkTextFieldStyle())
                        Text("Requires Ollama running locally.")
                            .font(Theme.sans(11)).foregroundStyle(Theme.textSecondary)
                    }

                    if selectedProvider.requiresAPIKey {
                        Text("Your messages are processed by \(selectedProvider.displayName) to generate summaries.")
                            .font(Theme.sans(11)).foregroundStyle(Theme.textSecondary)
                    }
                }

                Button("Continue") { saveLLMSettings(); withAnimation(Theme.quick) { step = .prepareSync } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!llmValid)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Step 3: Prepare Sync

    private var prepareSyncStep: some View {
        VStack(spacing: 28) {
            Spacer()

            stepHeader(
                title: "Almost ready",
                subtitle: "Before your first digest, we'll do two things in the background."
            )

            VStack(spacing: 12) {
                whyCard(
                    icon: "calendar.badge.clock",
                    title: "Build your 7-day history",
                    body: "We read your last week of messages so your first digest has full context — not just what arrives from today forward."
                )
                whyCard(
                    icon: "person.2.fill",
                    title: "Sync your contacts",
                    body: "We match phone numbers to names so digests say \"Mom\" and \"Anna\" instead of \"+49 123 456 7890\"."
                )
                whyCard(
                    icon: "checkmark.square",
                    title: "You approve before anything is sent",
                    body: "The Act tab queues proposed replies and follow-ups. Nothing goes out until you tap Approve — or edit it first."
                )
            }

            Button("Start Building") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                withAnimation(Theme.quick) { step = .syncing }
            }
            .buttonStyle(PrimaryButtonStyle())

            Spacer()
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Step 4: Syncing + How To Use

    private var syncingStep: some View {
        VStack(spacing: 28) {
            Spacer()

            // Progress / ready
            VStack(spacing: 12) {
                if firstBriefReady {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.ok)
                    Text("Your first digest is ready.")
                        .font(Theme.sans(13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    ProgressView()
                        .scaleEffect(1.3)
                        .tint(Theme.textSecondary)
                    Text("Reading your messages and writing your first digest…")
                        .font(Theme.sans(13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: firstBriefReady)

            // Rotating tips
            VStack(alignment: .leading, spacing: 8) {
                Text("WHILE YOU WAIT")
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.5)

                Text(tips[tipIndex % tips.count])
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.3), value: tipIndex)
            }
            .padding(16)
            .surfaceCard()

            Button(firstBriefReady ? "Open your first digest →" : "Open LLMessenger →") { onComplete() }
                .buttonStyle(PrimaryButtonStyle())

            Spacer()
        }
        .padding(.horizontal, 48)
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in
            guard step == .syncing else { return }
            tipIndex += 1
            if !firstBriefReady {
                firstBriefReady = (try? BriefRepository(database: database).latestBriefID()) != nil
            }
        }
    }

    // MARK: - Reusable Components

    private func serviceRow<Content: View>(
        title: String, icon: String, color: Color,
        isEnabled: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 8) {
            // Header toggle
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(color.opacity(0.5), lineWidth: 1)
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(Theme.sans(16))
                        .foregroundStyle(color)
                }
                Text(title).font(Theme.display(15))
                Spacer()
                Toggle("", isOn: isEnabled).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(isEnabled.wrappedValue ? color.opacity(0.35) : Theme.border,
                                  lineWidth: Theme.hairline)
            )

            // Inline setup when enabled
            if isEnabled.wrappedValue {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.quick, value: isEnabled.wrappedValue)
    }

    private func whyCard(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(Theme.sans(18))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.sans(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(body)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private func statusPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(Theme.sans(12.5, weight: .semibold)).foregroundStyle(color)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(color.opacity(0.3), lineWidth: Theme.hairline))
    }

    private func credRow(label: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        HStack {
            Text(label)
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 64, alignment: .leading)
            if secure {
                SecureField(placeholder, text: text).textFieldStyle(DarkTextFieldStyle())
            } else {
                TextField(placeholder, text: text).textFieldStyle(DarkTextFieldStyle())
            }
        }
    }

    private func instructionRow(n: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n)
                .font(Theme.mono(11, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
            Text(text)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepHeader(title: String, subtitle: String?) -> some View {
        VStack(spacing: 8) {
            Text(title).font(Theme.headlineFont).foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Logic

    private var llmValid: Bool {
        switch selectedProvider {
        case .anthropic: return !anthropicKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .openai:    return !openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .ollama, .appleIntelligence: return true
        }
    }

    private var databaseIsEmpty: Bool {
        ((try? BriefRepository(database: database).latestBriefID()) ?? nil) == nil
    }

    private func saveLLMSettings() {
        repo.saveSelectedLLMProvider(selectedProvider)
        switch selectedProvider {
        case .appleIntelligence: break
        case .anthropic: try? repo.saveLLMKey(provider: .anthropic, key: anthropicKey)
        case .openai:    try? repo.saveLLMKey(provider: .openai, key: openAIKey)
        case .ollama:
            let m = ollamaModel.trimmingCharacters(in: .whitespaces)
            repo.saveOllamaModel(m.isEmpty ? "llama3.1" : m)
        }
    }

    private func saveAllServices() {
        saveServiceEnabled("imessage", imessageEnabled)
        saveServiceEnabled("signal", signalEnabled)
        if signalEnabled, !signalNumber.trimmingCharacters(in: .whitespaces).isEmpty {
            try? repo.saveSignalAccount(signalNumber)
        }
        if !telegramEnabled { saveServiceEnabled("telegram", false) }
    }

    private func saveServiceEnabled(_ service: String, _ enabled: Bool) {
        var config = ServiceConfig.default(for: service)
        config.enabled = enabled
        try? repo.saveServiceConfig(config)
    }

    private func connectTelegram() {
        guard let path = telegramAdapterPath() else { return }
        let id   = telegramApiId.trimmingCharacters(in: .whitespaces)
        let hash = telegramApiHash.trimmingCharacters(in: .whitespaces)
        try? SettingsRepository().saveTelegramCredentials(apiId: id, apiHash: hash)
        telegramAdapter = SubprocessAdapter(
            serviceID: "telegram", adapterPath: path,
            config: makeTelegramConfig(apiId: id, apiHash: hash)
        )
    }

    private func buildTelegramAdapterIfNeeded() {
        let creds = SettingsRepository().loadTelegramCredentials()
        if telegramApiId.isEmpty  { telegramApiId   = creds.apiId }
        if telegramApiHash.isEmpty { telegramApiHash = creds.apiHash }
        guard telegramAdapter == nil,
              let path = telegramAdapterPath(),
              !creds.apiId.isEmpty, !creds.apiHash.isEmpty else { return }
        telegramAdapter = SubprocessAdapter(
            serviceID: "telegram", adapterPath: path,
            config: makeTelegramConfig(apiId: creds.apiId, apiHash: creds.apiHash)
        )
        // Session file means the user already authenticated — skip sign-in flow.
        let sessionPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llmessenger/data/telegram/session.session").path
        if FileManager.default.fileExists(atPath: sessionPath) {
            telegramConnected = true
        }
    }

    private func telegramAdapterPath() -> String? {
        if let p = Bundle.main.path(forResource: "telegram-adapter", ofType: nil),
           FileManager.default.fileExists(atPath: p) { return p }
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llmessenger/adapters/telegram/telegram-adapter").path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    private func makeTelegramConfig(apiId: String, apiHash: String) -> [String: Any] {
        let session = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llmessenger/data/telegram/session").path
        return ["api_id": apiId, "api_hash": apiHash, "session_path": session]
    }

    private static func checkFullDiskAccess() -> Bool {
        FileManager.default.isReadableFile(atPath: NSHomeDirectory() + "/Library/Messages/chat.db")
    }
}

// MARK: - View Modifier

private extension View {
    func surfaceCard() -> some View {
        self
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: Theme.hairline))
    }
}

// MARK: - Button Styles

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(13, weight: .semibold))
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.textPrimary))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
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
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
            .foregroundStyle(Theme.textPrimary)
            .font(Theme.sans(12.5))
    }
}

// ponytail: WireActionStyle was used only for demo in old welcome step; removed with welcome step.
