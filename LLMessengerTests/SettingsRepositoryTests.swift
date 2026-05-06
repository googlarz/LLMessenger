// LLMessengerTests/SettingsRepositoryTests.swift
import XCTest
@testable import LLMessenger

final class SettingsRepositoryTests: XCTestCase {

    func testSaveAndLoadLLMProvider() throws {
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store)

        try repo.saveLLMKey(provider: .anthropic, key: "sk-ant-test")
        let loaded = try repo.loadLLMKey(provider: .anthropic)
        XCTAssertEqual(loaded, "sk-ant-test")
    }

    func testLoadMissingKeyReturnsNil() throws {
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store)
        let loaded = try repo.loadLLMKey(provider: .openai)
        XCTAssertNil(loaded)
    }

    func testDeleteLLMKey() throws {
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store)
        try repo.saveLLMKey(provider: .anthropic, key: "sk-ant-test")
        try repo.deleteLLMKey(provider: .anthropic)
        let loaded = try repo.loadLLMKey(provider: .anthropic)
        XCTAssertNil(loaded)
    }

    func testSaveAndLoadServiceConfig() throws {
        let db = try AppDatabase(inMemory: true)
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store, database: db)

        var cfg = ServiceConfig.default(for: "telegram")
        cfg.pollIntervalMinutes = 45
        cfg.privacyMode = "eager"
        try repo.saveServiceConfig(cfg)

        let loaded = try repo.loadServiceConfig(for: "telegram")
        XCTAssertEqual(loaded?.pollIntervalMinutes, 45)
        XCTAssertEqual(loaded?.privacyMode, "eager")
    }

    func testSaveServiceConfigUpdatesExisting() throws {
        let db = try AppDatabase(inMemory: true)
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store, database: db)

        var cfg = ServiceConfig.default(for: "telegram")
        try repo.saveServiceConfig(cfg)

        cfg.pollIntervalMinutes = 60
        try repo.saveServiceConfig(cfg)

        let loaded = try repo.loadServiceConfig(for: "telegram")
        XCTAssertEqual(loaded?.pollIntervalMinutes, 60)
    }

    func testSaveAndLoadSignalAccount() throws {
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store, database: nil)
        try repo.saveSignalAccount("+12345678900")
        let loaded = try repo.loadSignalAccount()
        XCTAssertEqual(loaded, "+12345678900")
    }

    func testLoadSignalAccountReturnsNilWhenNotSet() throws {
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store, database: nil)
        let loaded = try repo.loadSignalAccount()
        XCTAssertNil(loaded)
    }
}
