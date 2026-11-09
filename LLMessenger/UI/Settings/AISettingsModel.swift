// LLMessenger/UI/Settings/AISettingsModel.swift
//
// Draft state for Settings → AI & Privacy → AI. Owned by SettingsView, so a typed API key
// or a half-changed provider survives switching sub-tab or pane. Nothing here takes effect
// until Save: choosing a cloud provider changes where message text goes, which is a
// decision the user should confirm, not something we save on their way out.

import Foundation

@MainActor
final class AISettingsModel: ObservableObject {
    struct Values: Equatable {
        var selectedProviderRaw = ""
        var anthropicKey = ""
        var openAIKey = ""
        var ollamaModel = ""
        var cloudAutoBriefsConsent = false
    }

    enum Status: Equatable {
        case idle
        case saved
        case error(String)
    }

    @Published var values = Values()
    @Published private(set) var saved = Values()
    @Published private(set) var status: Status = .idle

    private let repo: SettingsRepository
    private let center: NotificationCenter
    private var clearTask: Task<Void, Never>?

    init(repo: SettingsRepository = SettingsRepository(), center: NotificationCenter = .default) {
        self.repo = repo
        self.center = center
        // Not loaded here: reading API keys touches the Keychain, and merely creating the
        // Settings window must not. The AI tab calls `load()` when it appears.
    }

    var isDirty: Bool { values != saved }

    var selectedProvider: LLMProvider? { LLMProvider(rawValue: values.selectedProviderRaw) }
    var selectedProviderIsCloud: Bool { selectedProvider?.isCloud == true }

    /// Re-reads stored settings, unless the user has unsaved edits that a reload would erase.
    func load() {
        guard !isDirty else { return }
        let loaded = Values(
            selectedProviderRaw: repo.loadSelectedLLMProvider()?.rawValue ?? "",
            anthropicKey: (try? repo.loadLLMKey(provider: .anthropic)) ?? "",
            openAIKey: (try? repo.loadLLMKey(provider: .openai)) ?? "",
            ollamaModel: repo.loadOllamaModel(),
            cloudAutoBriefsConsent: repo.loadCloudAutoBriefsConsent())
        values = loaded
        saved = loaded
    }

    func save() {
        do {
            let provider = selectedProvider
            repo.saveSelectedLLMProvider(provider)
            try repo.saveLLMKey(provider: .anthropic, key: values.anthropicKey)
            try repo.saveLLMKey(provider: .openai, key: values.openAIKey)
            repo.saveOllamaModel(values.ollamaModel)
            // Consent only means something for a cloud provider; never keep it on otherwise.
            values.cloudAutoBriefsConsent = provider?.isCloud == true && values.cloudAutoBriefsConsent
            repo.saveCloudAutoBriefsConsent(values.cloudAutoBriefsConsent)
            saved = values
            center.post(name: .llmProviderDidChange, object: nil)
            flashSaved()
        } catch {
            // Keep the typed values so the user can retry.
            status = .error("Couldn't save: \(error.localizedDescription) Your changes are still here.")
        }
    }

    func discard() {
        values = saved
        status = .idle
    }

    private func flashSaved() {
        status = .saved
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.status == .saved { self?.status = .idle }
        }
    }
}

/// What the AI tab tells the user about where their messages go for the chosen provider.
enum AIProviderDisclosure {
    /// One plain line shown when a cloud provider is selected; nil for local providers.
    static func cloudNotice(for provider: LLMProvider?) -> String? {
        guard let provider, provider.isCloud else { return nil }
        return "Message content will be sent to \(provider.displayName) to build digests and drafts."
    }
}

/// The "usage this month" row label for runs whose prompt had to be shortened.
enum LLMUsageLabel {
    static func trimmedRuns(_ count: Int) -> String {
        count == 1 ? "1 run trimmed to fit" : "\(count) runs trimmed to fit"
    }
}
