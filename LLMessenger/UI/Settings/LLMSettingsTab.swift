// LLMessenger/UI/Settings/LLMSettingsTab.swift
import SwiftUI
import ServiceManagement

struct AISettingsTab: View {
    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    @State private var ollamaModel: String = ""
    @State private var launchAtLogin: Bool = false
    @State private var saveStatus: String = ""

    private let repo = SettingsRepository()

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("API Key (sk-ant-…)", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
                Text("Powers claude-3-5-sonnet and other Anthropic models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI") {
                SecureField("API Key (sk-…)", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Fallback when no Anthropic key is set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ollama (local)") {
                TextField("Model name (e.g. llama3, mistral)", text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)
                Text("Runs locally via Ollama. Used when no cloud keys are set.")
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
        anthropicKey = (try? repo.loadLLMKey(provider: .anthropic)) ?? ""
        openAIKey    = (try? repo.loadLLMKey(provider: .openai))    ?? ""
        ollamaModel  = UserDefaults.standard.string(forKey: "ollama_model") ?? ""
        launchAtLogin = AutoLaunchManager.isEnabled
    }

    private func save() {
        do {
            try repo.saveLLMKey(provider: .anthropic, key: anthropicKey)
            try repo.saveLLMKey(provider: .openai,    key: openAIKey)
            UserDefaults.standard.set(ollamaModel, forKey: "ollama_model")
            saveStatus = "Saved ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }
}
