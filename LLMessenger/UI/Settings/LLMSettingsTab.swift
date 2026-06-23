// LLMessenger/UI/Settings/LLMSettingsTab.swift
import SwiftUI
import ServiceManagement
import GRDB

struct AISettingsTab: View {
    var database: AppDatabase? = nil

    @State private var selectedProviderRaw: String = ""
    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    @State private var ollamaModel: String = ""
    @State private var cloudAutoBriefsConsent: Bool = false
    @State private var launchAtLogin: Bool = false
    @State private var saveStatus: String = ""
    @State private var testState: TestState = .idle
    @State private var usageRows: [(provider: String, inputK: Int, outputK: Int, cost: Double)] = []
    @State private var isLocalOnlyMode: Bool = SettingsRepository().loadLocalOnlyMode()

    private let repo = SettingsRepository()

    enum TestState {
        case idle
        case running
        case success(String)   // model name that responded
        case failure(String)   // error message
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("AI Backend") {
                        if isLocalOnlyMode {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.ok)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Local-only mode is active")
                                        .font(Theme.mono(11, weight: .semibold))
                                        .tracking(0.6)
                                        .foregroundStyle(Theme.ok)
                                    Text("Cloud providers are disabled. Change this in the Privacy tab.")
                                        .font(Theme.sans(11.5))
                                        .foregroundStyle(Theme.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 6)
                        }

                        Picker("Provider", selection: $selectedProviderRaw) {
                            Text("Choose...").tag("")
                            ForEach(LLMProvider.availableCases, id: \.rawValue) { provider in
                                Text(provider.displayName).tag(provider.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(isLocalOnlyMode && selectedProviderIsCloud)

                        caption("LLMessenger only uses the backend selected here. API keys by themselves never enable cloud processing.")
                    }

                    Rule()

                    section("Anthropic") {
                        SecureField("API Key (sk-ant-…)", text: $anthropicKey)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.sans(13))
                        caption("Used only when Anthropic is explicitly selected above.")
                    }

                    Rule()

                    section("OpenAI") {
                        SecureField("API Key (sk-…)", text: $openAIKey)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.sans(13))
                        caption("Used only when OpenAI is explicitly selected above.")
                    }

                    Rule()

                    section("Ollama — Local") {
                        OllamaModelPicker(selectedModel: $ollamaModel)
                        caption("Runs locally via Ollama when Ollama is explicitly selected above. The picker loads available models from the local Ollama API; falls back to a text field if Ollama is not running.")
                    }

                    Rule()

                    section("Automatic Digest Privacy") {
                        Toggle("Allow automatic digests with the selected cloud provider", isOn: $cloudAutoBriefsConsent)
                            .toggleStyle(.switch).controlSize(.small)
                            .font(Theme.sans(13))
                            .tint(Theme.ok)
                            .disabled(!selectedProviderIsCloud)
                        caption(consentHelpText)
                    }

                    Rule()

                    section("General") {
                        Toggle("Launch at login", isOn: $launchAtLogin)
                            .toggleStyle(.switch).controlSize(.small)
                            .font(Theme.sans(13))
                            .tint(Theme.ok)
                            .onChange(of: launchAtLogin) { enabled in
                                try? AutoLaunchManager.setEnabled(enabled)
                            }
                    }

                    Rule()

                    section("Connection") {
                        Button(action: { Task { await testConnection() } }) {
                            if case .running = testState {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Testing…")
                                }
                            } else {
                                Text("Test AI Connection")
                            }
                        }
                        .buttonStyle(PaperButtonStyle())
                        .disabled(currentClientSpec == nil || testState == .running)

                        switch testState {
                        case .idle, .running:
                            EmptyView()
                        case .success(let model):
                            statusLine("Connected — \(model) responded", color: Theme.ok)
                        case .failure(let msg):
                            statusLine(msg, color: Theme.signal)
                        }

                        caption("Sends a one-word test prompt using the settings above (no need to save first).")
                    }

                    if !usageRows.isEmpty {
                        Rule()
                        usageSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Rule()

            // Footer: status + save
            HStack {
                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(PaperButtonStyle(prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear { load(); isLocalOnlyMode = repo.loadLocalOnlyMode() }
        .task { await loadUsage() }
    }

    // MARK: - Section scaffolding

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WireLabel(title)
            content()
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.sans(11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var usageSection: some View {
        section("Usage This Month") {
            ForEach(usageRows, id: \.provider) { row in
                HStack {
                    Text(row.provider)
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(row.inputK)k in / \(row.outputK)k out")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textTertiary)
                    Text("est. $\(String(format: "%.4f", row.cost))")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            let total = usageRows.reduce(0) { $0 + $1.cost }
            Rule()
            HStack {
                Text("Total")
                    .font(Theme.sans(12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("est. $\(String(format: "%.4f", total))")
                    .font(Theme.mono(11, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    // MARK: - Test

    private struct ClientSpec {
        let client: LLMClient
        let model: String
        let label: String
    }

    private var currentClientSpec: ClientSpec? {
        guard let provider = LLMProvider(rawValue: selectedProviderRaw) else { return nil }
        switch provider {
        case .appleIntelligence:
            return ClientSpec(client: provider.makeClient(apiKey: nil),
                              model: provider.defaultModel,
                              label: "On-Device / Apple Intelligence")
        case .anthropic:
            let key = anthropicKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return ClientSpec(client: provider.makeClient(apiKey: key),
                              model: provider.defaultModel,
                              label: "\(provider.displayName) / \(provider.defaultModel)")
        case .openai:
            let key = openAIKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return ClientSpec(client: provider.makeClient(apiKey: key),
                              model: provider.defaultModel,
                              label: "\(provider.displayName) / \(provider.defaultModel)")
        case .ollama:
            let model = ollamaModel.trimmingCharacters(in: .whitespaces)
            let m = model.isEmpty ? provider.defaultModel : model
            return ClientSpec(client: provider.makeClient(apiKey: nil),
                              model: m,
                              label: "Ollama / \(m)")
        }
    }

    private func testConnection() async {
        guard let spec = currentClientSpec else { return }
        testState = .running
        do {
            _ = try await spec.client.complete(
                model: spec.model,
                messages: [LLMMessage(role: .user, content: "Reply with just the word OK.")],
                maxTokens: 10
            )
            testState = .success(spec.label)
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    // MARK: - Load / Save

    private func load() {
        selectedProviderRaw = repo.loadSelectedLLMProvider()?.rawValue ?? ""
        anthropicKey = (try? repo.loadLLMKey(provider: .anthropic)) ?? ""
        openAIKey    = (try? repo.loadLLMKey(provider: .openai))    ?? ""
        ollamaModel  = repo.loadOllamaModel()
        cloudAutoBriefsConsent = repo.loadCloudAutoBriefsConsent()
        launchAtLogin = AutoLaunchManager.isEnabled
    }

    private func save() {
        do {
            let selectedProvider = LLMProvider(rawValue: selectedProviderRaw)
            repo.saveSelectedLLMProvider(selectedProvider)
            try repo.saveLLMKey(provider: .anthropic, key: anthropicKey)
            try repo.saveLLMKey(provider: .openai,    key: openAIKey)
            repo.saveOllamaModel(ollamaModel)
            repo.saveCloudAutoBriefsConsent(selectedProvider?.isCloud == true && cloudAutoBriefsConsent)
            NotificationCenter.default.post(name: .llmProviderDidChange, object: nil)
            saveStatus = "Saved ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Usage

    private func loadUsage() async {
        guard let db = database else { return }
        let calendar = Calendar.current
        let now = Date()
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else { return }

        struct UsageRow: Decodable, FetchableRecord {
            let backend: String
            let totalInput: Int
            let totalOutput: Int
        }

        let rows = (try? await db.dbQueue.read { dbConn in
            try UsageRow.fetchAll(dbConn, sql: """
                SELECT backend,
                       COALESCE(SUM(inputTokenEstimate), 0)  AS totalInput,
                       COALESCE(SUM(outputTokenEstimate), 0) AS totalOutput
                FROM llmRuns
                WHERE startedAt >= ?
                GROUP BY backend
                """, arguments: [monthStart])
        }) ?? []

        usageRows = rows.map { row in
            let cost: Double
            let b = row.backend.lowercased()
            if b.contains("anthropic") {
                cost = Double(row.totalInput) * 3.0 / 1_000_000 + Double(row.totalOutput) * 15.0 / 1_000_000
            } else if b.contains("openai") {
                cost = Double(row.totalInput) * 2.50 / 1_000_000 + Double(row.totalOutput) * 10.0 / 1_000_000
            } else {
                cost = 0
            }
            return (provider: row.backend, inputK: row.totalInput / 1000, outputK: row.totalOutput / 1000, cost: cost)
        }
    }

    private var selectedProviderIsCloud: Bool {
        LLMProvider(rawValue: selectedProviderRaw)?.isCloud == true
    }

    private var consentHelpText: String {
        if selectedProviderIsCloud {
            return "When enabled, automatic digests may send included message content to the selected cloud provider. Manual digests still use the selected backend when you run them."
        }
        return "Automatic cloud consent is only needed when Anthropic or OpenAI is selected."
    }
}

extension AISettingsTab.TestState: Equatable {
    static func == (lhs: AISettingsTab.TestState, rhs: AISettingsTab.TestState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.running, .running): return true
        case (.success(let a), .success(let b)):   return a == b
        case (.failure(let a), .failure(let b)):   return a == b
        default: return false
        }
    }
}
