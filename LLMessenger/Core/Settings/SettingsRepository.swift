// LLMessenger/Core/Settings/SettingsRepository.swift
import Foundation

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

    // MARK: - Signal Account (stored in UserDefaults — not sensitive)

    func saveSignalAccount(_ number: String) throws {
        if number.isEmpty {
            UserDefaults.standard.removeObject(forKey: "signal_account")
        } else {
            UserDefaults.standard.set(number, forKey: "signal_account")
        }
    }

    func loadSignalAccount() throws -> String? {
        UserDefaults.standard.string(forKey: "signal_account")
    }

    // MARK: - Service Config

    func saveServiceConfig(_ config: ServiceConfig) throws {
        guard let db = database else { return }
        try db.dbQueue.write { db in
            try config.save(db)
        }
    }

    func loadServiceConfig(for service: String) throws -> ServiceConfig? {
        guard let db = database else { return nil }
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
        guard let db = database else { return [] }
        return try db.dbQueue.read { db in
            try ServiceConfig.fetchAll(db)
        }
    }
}
