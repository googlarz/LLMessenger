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

    func testSaveAndLoadSelectedLLMProvider() throws {
        let defaults = try makeIsolatedDefaults()
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store, userDefaults: defaults)

        repo.saveSelectedLLMProvider(.openai)

        XCTAssertEqual(repo.loadSelectedLLMProvider(), .openai)
    }

    func testMissingSelectedLLMProviderReturnsNilEvenWhenKeyExists() throws {
        let defaults = try makeIsolatedDefaults()
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store, userDefaults: defaults)

        try repo.saveLLMKey(provider: .anthropic, key: "sk-ant-test")

        XCTAssertNil(repo.loadSelectedLLMProvider())
    }

    func testCloudAutoBriefConsentDefaultsFalse() throws {
        let defaults = try makeIsolatedDefaults()
        let repo = SettingsRepository(userDefaults: defaults)

        XCTAssertFalse(repo.loadCloudAutoBriefsConsent())
    }

    func testSaveAndLoadCloudAutoBriefConsent() throws {
        let defaults = try makeIsolatedDefaults()
        let repo = SettingsRepository(userDefaults: defaults)

        repo.saveCloudAutoBriefsConsent(true)

        XCTAssertTrue(repo.loadCloudAutoBriefsConsent())
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "llmessenger-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
