// LLMessengerTests/SettingsRepositoryTests.swift
import XCTest
@testable import LLMessenger

final class SettingsRepositoryTests: XCTestCase {

    // Each test instance gets a unique prefix so concurrent tests don't collide.
    // Keys are cleaned up after every test.
    private var prefix: String = ""
    private var store: KeychainStore!

    override func setUp() {
        prefix = "_test_\(UUID().uuidString.prefix(8))_"
        store = KeychainStore(service: "LLMessengerSettingsTests-\(UUID().uuidString)", account: "credentials")
    }

    override func tearDown() {
        // Clean up any keys this test may have written.
        for suffix in ["anthropic", "openai", "signal_account",
                       "telegram_api_id", "telegram_api_hash"] {
            try? store.delete(account: "\(prefix)\(suffix)")
        }
        store.deleteStore()
        store = nil
    }

    func testSaveAndLoadLLMProvider() throws {
        let repo = SettingsRepository(keychainStore: store, keyPrefix: prefix)
        try repo.saveLLMKey(provider: .anthropic, key: "sk-ant-test")
        let loaded = try repo.loadLLMKey(provider: .anthropic)
        XCTAssertEqual(loaded, "sk-ant-test")
    }

    func testLoadMissingKeyReturnsNil() throws {
        let repo = SettingsRepository(keychainStore: store, keyPrefix: prefix)
        let loaded = try repo.loadLLMKey(provider: .openai)
        XCTAssertNil(loaded)
    }

    func testDeleteLLMKey() throws {
        let repo = SettingsRepository(keychainStore: store, keyPrefix: prefix)
        try repo.saveLLMKey(provider: .anthropic, key: "sk-ant-test")
        try repo.deleteLLMKey(provider: .anthropic)
        let loaded = try repo.loadLLMKey(provider: .anthropic)
        XCTAssertNil(loaded)
    }

    func testSaveAndLoadServiceConfig() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = SettingsRepository(keychainStore: store, keyPrefix: prefix, database: db)

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
        let repo = SettingsRepository(keychainStore: store, keyPrefix: prefix, database: db)

        var cfg = ServiceConfig.default(for: "telegram")
        try repo.saveServiceConfig(cfg)

        cfg.pollIntervalMinutes = 60
        try repo.saveServiceConfig(cfg)

        let loaded = try repo.loadServiceConfig(for: "telegram")
        XCTAssertEqual(loaded?.pollIntervalMinutes, 60)
    }

    func testSaveAndLoadSignalAccount() throws {
        let repo = SettingsRepository(keychainStore: store, keyPrefix: prefix, database: nil)
        try repo.saveSignalAccount("+12345678900")
        let loaded = try repo.loadSignalAccount()
        XCTAssertEqual(loaded, "+12345678900")
    }

    func testLoadSignalAccountReturnsNilWhenNotSet() throws {
        let repo = SettingsRepository(keychainStore: store, keyPrefix: prefix, database: nil)
        let loaded = try repo.loadSignalAccount()
        XCTAssertNil(loaded)
    }

    func testSaveAndLoadSelectedLLMProvider() throws {
        let defaults = try makeIsolatedDefaults()
        let repo = SettingsRepository(keychainStore: store, keyPrefix: prefix,
                                      userDefaults: defaults)
        repo.saveSelectedLLMProvider(.openai)
        XCTAssertEqual(repo.loadSelectedLLMProvider(), .openai)
    }

    func testMissingSelectedLLMProviderReturnsNilEvenWhenKeyExists() throws {
        let defaults = try makeIsolatedDefaults()
        let repo = SettingsRepository(keychainStore: store, keyPrefix: prefix,
                                      userDefaults: defaults)
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
