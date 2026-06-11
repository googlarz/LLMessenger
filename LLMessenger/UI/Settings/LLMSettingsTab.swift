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

    private let repo = SettingsRepository()

    enum TestState {
        case idle
        case running
        case success(String)   // model name that responded
        case failure(String)   // error message
    }

    var body: some View {
        Form {
            Section("AI Backend") {
                Picker("Provider", selection: $selectedProviderRaw) {
                    Text("Choose...").tag("")
                    ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("LLMessenger only uses the backend selected here. API keys by themselves never enable cloud processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Anthropic") {
                SecureField("API Key (sk-ant-…)", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
                Text("Used only when Anthropic is explicitly selected above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI") {
                SecureField("API Key (sk-…)", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Used only when OpenAI is explicitly selected above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ollama (local)") {
                OllamaModelPicker(selectedModel: $ollamaModel)
                Text("Runs locally via Ollama when Ollama is explicitly selected above. The picker loads available models from the local Ollama API; falls back to a text field if Ollama is not running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Automatic Brief Privacy") {
                Toggle("Allow automatic briefs with the selected cloud provider", isOn: $cloudAutoBriefsConsent)
                    .disabled(!selectedProviderIsCloud)
                Text(consentHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        try? AutoLaunchManager.setEnabled(enabled)
                    }
            }

            // Test connection row
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button(action: { Task { await testConnection() } }) {
                            if case .running = testState {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Testing…")
                                }
                            } else {
                                Label("Test AI Connection", systemImage: "bolt.circle")
                            }
                        }
                        .disabled(currentClientSpec == nil || testState == .running)
                    }

                    switch testState {
                    case .idle:
                        EmptyView()
                    case .running:
                        EmptyView()
                    case .success(let model):
                        Label("Connected — \(model) responded", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } footer: {
                Text("Sends a one-word test prompt using the settings above (no need to save first).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !usageRows.isEmpty {
                Section("Usage this month") {
                    ForEach(usageRows, id: \.provider) { row in
                        HStack {
                            Text(row.provider)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(row.inputK)k in / \(row.outputK)k out")
                                .foregroundStyle(.secondary)
                            Text("est. $\(String(format: "%.4f", row.cost))")
                                .monospacedDigit()
                        }
                    }
                    let total = usageRows.reduce(0) { $0 + $1.cost }
                    HStack {
                        Text("Total")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .bold()
                        Text("est. $\(String(format: "%.4f", total))")
                            .monospacedDigit()
                            .bold()
                    }
                }
            }

            HStack {
                Spacer()
                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onAppear { load() }
        .task { await loadUsage() }
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
            return "When enabled, automatic briefs may send included message content to the selected cloud provider. Manual briefs still use the selected backend when you run them."
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
