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

    // MARK: - Signal Account

    func saveSignalAccount(_ number: String) throws {
        if number.isEmpty {
            try? keychainStore.delete(account: "signal_account")
        } else {
            try keychainStore.set(account: "signal_account", value: number)
        }
    }

    func loadSignalAccount() throws -> String? {
        do {
            return try keychainStore.get(account: "signal_account")
        } catch KeychainError.itemNotFound {
            return nil
        }
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

    func loadAllServiceConfigs() throws -> [ServiceConfig] {
        guard let db = database else { return [] }
        return try db.dbQueue.read { db in
            try ServiceConfig.fetchAll(db)
        }
    }
}
