// LLMessenger/Core/Settings/SettingsRepository.swift
import Foundation

enum SettingsError: Error, LocalizedError {
    case databaseNotConfigured

    var errorDescription: String? { "Settings database is not configured" }
}

struct SettingsRepository {
    private let keychainStore: KeychainStore
    private let database: AppDatabase?

    init(keychainStore: KeychainStore = KeychainStore(), database: AppDatabase? = nil) {
        self.keychainStore = keychainStore
        self.database = database
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
        UserDefaults.standard.set(prompt, forKey: "base_prompt")
    }

    func loadBasePrompt() -> String {
        UserDefaults.standard.string(forKey: "base_prompt") ?? ""
    }

    // MARK: - Theme

    func saveTheme(_ theme: String) {
        UserDefaults.standard.set(theme, forKey: "app_theme")
    }

    func loadTheme() -> String {
        UserDefaults.standard.string(forKey: "app_theme") ?? "system"
    }

    // MARK: - Default poll interval (minutes)

    func savePollInterval(_ minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: "default_poll_interval")
    }

    func loadPollInterval() -> Int {
        let v = UserDefaults.standard.integer(forKey: "default_poll_interval")
        return v > 0 ? v : 60
    }

    func loadAllServiceConfigs() throws -> [ServiceConfig] {
        guard let db = database else { throw SettingsError.databaseNotConfigured }
        return try db.dbQueue.read { db in
            try ServiceConfig.fetchAll(db)
        }
    }
}
