// LLMessenger/Core/Settings/SettingsRepository.swift
import Foundation

enum SettingsError: Error, LocalizedError {
    case databaseNotConfigured

    var errorDescription: String? { "Settings database is not configured" }
}

struct SettingsRepository {
    private let keychainStore: KeychainStore
    private let database: AppDatabase?
    private let userDefaults: UserDefaults

    init(keychainStore: KeychainStore = KeychainStore(),
         database: AppDatabase? = nil,
         userDefaults: UserDefaults = .standard) {
        self.keychainStore = keychainStore
        self.database = database
        self.userDefaults = userDefaults
    }

    // MARK: - LLM Keys

    func saveLLMKey(provider: LLMProvider, key: String) throws {
        if key.isEmpty {
            try keychainStore.delete(account: provider.rawValue)
        } else {
            try keychainStore.set(account: provider.rawValue, value: key)
        }
    }

    func loadLLMKey(provider: LLMProvider) throws -> String? {
        do {
            return try keychainStore.get(account: provider.rawValue)
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    func deleteLLMKey(provider: LLMProvider) throws {
        try keychainStore.delete(account: provider.rawValue)
    }

    func saveSelectedLLMProvider(_ provider: LLMProvider?) {
        if let provider {
            userDefaults.set(provider.rawValue, forKey: "selected_llm_provider")
        } else {
            userDefaults.removeObject(forKey: "selected_llm_provider")
        }
    }

    func loadSelectedLLMProvider() -> LLMProvider? {
        guard let raw = userDefaults.string(forKey: "selected_llm_provider") else { return nil }
        return LLMProvider(rawValue: raw)
    }

    func saveCloudAutoBriefsConsent(_ consent: Bool) {
        userDefaults.set(consent, forKey: "cloud_auto_briefs_consent")
    }

    func loadCloudAutoBriefsConsent() -> Bool {
        userDefaults.bool(forKey: "cloud_auto_briefs_consent")
    }

    /// Local-only mode forces the LLM to Ollama and skips registering any adapter that
    /// would send message content off this Mac (currently Slack). When this is on,
    /// no message content can leave the machine.
    func saveLocalOnlyMode(_ on: Bool) {
        userDefaults.set(on, forKey: "local_only_mode")
    }

    func loadLocalOnlyMode() -> Bool {
        userDefaults.bool(forKey: "local_only_mode")
    }

    /// Pre-send sanitization redacts patterns that match credit cards, SSNs, and emails
    /// before the prompt is sent to a cloud LLM. Off by default.
    func saveSanitizeBeforeSend(_ on: Bool) {
        userDefaults.set(on, forKey: "sanitize_before_send")
    }

    func loadSanitizeBeforeSend() -> Bool {
        userDefaults.bool(forKey: "sanitize_before_send")
    }

    func saveOllamaModel(_ model: String) {
        if model.isEmpty {
            userDefaults.removeObject(forKey: "ollama_model")
        } else {
            userDefaults.set(model, forKey: "ollama_model")
        }
    }

    func loadOllamaModel() -> String {
        userDefaults.string(forKey: "ollama_model") ?? ""
    }

    // MARK: - Telegram Credentials (stored in keychain)

    func saveTelegramCredentials(apiId: String, apiHash: String) throws {
        if apiId.isEmpty {
            try? keychainStore.delete(account: "telegram_api_id")
        } else {
            try keychainStore.set(account: "telegram_api_id", value: apiId)
        }
        if apiHash.isEmpty {
            try? keychainStore.delete(account: "telegram_api_hash")
        } else {
            try keychainStore.set(account: "telegram_api_hash", value: apiHash)
        }
    }

    func loadTelegramCredentials() -> (apiId: String, apiHash: String) {
        let apiId   = (try? keychainStore.get(account: "telegram_api_id"))  ?? ""
        let apiHash = (try? keychainStore.get(account: "telegram_api_hash")) ?? ""
        return (apiId, apiHash)
    }

    // MARK: - Signal Account (stored in Keychain)

    func saveSignalAccount(_ number: String) throws {
        if number.isEmpty {
            try? keychainStore.delete(account: "signal_account")
        } else {
            try keychainStore.set(account: "signal_account", value: number)
        }
    }

    func loadSignalAccount() throws -> String? {
        // One-time migration from UserDefaults — only remove the source after a confirmed write.
        if let legacy = UserDefaults.standard.string(forKey: "signal_account"), !legacy.isEmpty {
            do {
                try keychainStore.set(account: "signal_account", value: legacy)
                UserDefaults.standard.removeObject(forKey: "signal_account")
            } catch {
                // Keep the legacy value so migration retries on next launch.
            }
        }
        do {
            return try keychainStore.get(account: "signal_account")
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    // MARK: - Service Config

    func saveServiceConfig(_ config: ServiceConfig) throws {
        guard let db = database else { throw SettingsError.databaseNotConfigured }
        try db.dbQueue.write { db in
            try config.save(db)
        }
    }

    func loadServiceConfig(for service: String) throws -> ServiceConfig? {
        guard let db = database else { throw SettingsError.databaseNotConfigured }
        return try db.dbQueue.read { db in
            try ServiceConfig.fetchOne(db, key: service)
        }
    }

    // MARK: - Base Prompt

    func saveBasePrompt(_ prompt: String) {
        userDefaults.set(prompt, forKey: "base_prompt")
    }

    func loadBasePrompt() -> String {
        userDefaults.string(forKey: "base_prompt") ?? ""
    }

    // MARK: - Theme

    func saveTheme(_ theme: String) {
        userDefaults.set(theme, forKey: "app_theme")
    }

    func loadTheme() -> String {
        userDefaults.string(forKey: "app_theme") ?? "system"
    }

    // MARK: - Default poll interval (minutes)

    func savePollInterval(_ minutes: Int) {
        userDefaults.set(minutes, forKey: "default_poll_interval")
    }

    func loadPollInterval() -> Int {
        let v = userDefaults.integer(forKey: "default_poll_interval")
        return v > 0 ? v : 60
    }

    func loadAllServiceConfigs() throws -> [ServiceConfig] {
        guard let db = database else { throw SettingsError.databaseNotConfigured }
        return try db.dbQueue.read { db in
            try ServiceConfig.fetchAll(db)
        }
    }

    // MARK: - Service Health

    func loadServiceHealth(for service: String) throws -> ServiceHealth? {
        guard let db = database else { throw SettingsError.databaseNotConfigured }
        return try db.dbQueue.read { db in
            try ServiceHealth.fetchOne(db, key: service)
        }
    }

    func loadAllServiceHealth() throws -> [String: ServiceHealth] {
        guard let db = database else { throw SettingsError.databaseNotConfigured }
        let rows = try db.dbQueue.read { db in
            try ServiceHealth.fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.service, $0) })
    }

    // MARK: - Morning Digest

    func saveDigestSettings(_ settings: DigestScheduler.Settings) {
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: "digestSettings")
        }
    }

    func loadDigestSettings() -> DigestScheduler.Settings {
        guard let data = userDefaults.data(forKey: "digestSettings"),
              let s = try? JSONDecoder().decode(DigestScheduler.Settings.self, from: data)
        else { return DigestScheduler.Settings() }
        return s
    }
}
