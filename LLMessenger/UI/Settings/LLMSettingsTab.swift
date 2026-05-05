// LLMessenger/UI/Settings/LLMSettingsTab.swift
import SwiftUI

struct LLMSettingsTab: View {
    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    @State private var ollamaModel: String = ""
    @State private var saveStatus: String = ""

    private let repo = SettingsRepository()

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("API Key (sk-ant-…)", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("OpenAI") {
                SecureField("API Key (sk-…)", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Ollama (local)") {
                TextField("Model name (e.g. llama3)", text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)
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
        ollamaModel  = (try? repo.loadLLMKey(provider: .ollama))    ?? ""
    }

    private func save() {
        do {
            try repo.saveLLMKey(provider: .anthropic, key: anthropicKey)
            try repo.saveLLMKey(provider: .openai,    key: openAIKey)
            try repo.saveLLMKey(provider: .ollama,    key: ollamaModel)
            saveStatus = "Saved ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }
}
