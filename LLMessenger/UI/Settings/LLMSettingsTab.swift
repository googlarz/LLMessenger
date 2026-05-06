// LLMessenger/UI/Settings/LLMSettingsTab.swift
import SwiftUI
import ServiceManagement

struct AISettingsTab: View {
    @State private var selectedProviderRaw: String = ""
    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    @State private var ollamaModel: String = ""
    @State private var cloudAutoBriefsConsent: Bool = false
    @State private var launchAtLogin: Bool = false
    @State private var saveStatus: String = ""

    private let repo = SettingsRepository()

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
                TextField("Model name (e.g. llama3, mistral)", text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)
                Text("Runs locally via Ollama when Ollama is explicitly selected above.")
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
    }

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
            saveStatus = "Saved ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
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
