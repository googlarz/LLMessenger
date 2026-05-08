// LLMessengerTests/PollEngineReloadTests.swift
// Tests PollEngine.reload(config:) — the live config-update path.
//
// reload() is called when the user changes a service's settings (interval, enabled/disabled)
// while the engine is already running. If it doesn't correctly enable/disable polling,
// the service either keeps running after being disabled (privacy violation) or never
// resumes after being re-enabled (silent message loss).
import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class PollEngineReloadTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func makeConfig(service: String = "signal", enabled: Bool,
                            interval: Int = 30) -> ServiceConfig {
        ServiceConfig(service: service, enabled: enabled,
                      pollIntervalMinutes: interval, fetchMode: "time",
                      fetchLimit: 50, privacyMode: "eager")
    }

    // MARK: - Reload enables a previously disabled service

    func testReloadEnabledTrueAllowsSubsequentPollToFetch() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = PollEngine(database: db)
        // Register as disabled initially
        engine.register(adapter: adapter, config: makeConfig(enabled: false))
        await engine.pollAll()

        XCTAssertTrue(adapter.fetchConfigs.isEmpty,
                      "Precondition: disabled service must not be polled")

        // Re-enable via reload
        engine.reload(config: makeConfig(enabled: true))
        await engine.pollAll()

        XCTAssertFalse(adapter.fetchConfigs.isEmpty,
                       "After reload(enabled: true), the service must be polled on next pollAll()")
    }

    func testReloadEnabledTrueUpdatesStoredConfig() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = PollEngine(database: db)
        engine.register(adapter: adapter, config: makeConfig(enabled: false))

        engine.reload(config: makeConfig(enabled: true))
        await engine.pollAll()

        let count = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(count, 1,
                       "After reload(enabled: true), messages must be stored when pollAll runs")
    }

    // MARK: - Reload disables a previously enabled service

    func testReloadEnabledFalseSkipsServiceInSubsequentPollAll() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = PollEngine(database: db)
        engine.register(adapter: adapter, config: makeConfig(enabled: true))

        // First poll — service is enabled
        await engine.pollAll()
        let countAfterFirst = adapter.fetchConfigs.count
        XCTAssertGreaterThan(countAfterFirst, 0, "Precondition: enabled service must have been polled once")

        // Disable via reload
        engine.reload(config: makeConfig(enabled: false))
        await engine.pollAll()

        // Fetch count must not have increased — service is now disabled
        XCTAssertEqual(adapter.fetchConfigs.count, countAfterFirst,
                       "After reload(enabled: false), pollAll must skip the disabled service")
    }

    func testReloadEnabledFalseStopsMessageStorageForThatService() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = PollEngine(database: db)
        engine.register(adapter: adapter, config: makeConfig(enabled: true))
        await engine.pollAll()

        let countAfterFirst = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(countAfterFirst, 1, "Precondition: first poll stored the message")

        // Add new message and disable
        adapter.addMessage(convId: "c1", msgId: "m2")
        engine.reload(config: makeConfig(enabled: false))
        await engine.pollAll()

        let countAfterReload = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(countAfterReload, 1,
                       "After reload(enabled: false), new messages must NOT be stored for the disabled service")
    }

    // MARK: - Reload with multiple services

    func testReloadOnlyAffectsTargetedService() async throws {
        let db = try makeDB()
        let signalAdapter = FakeMessengerAdapter(serviceID: "signal")
        signalAdapter.addMessage(convId: "c1", msgId: "sig-m1", at: Date().addingTimeInterval(-5))
        let telegramAdapter = FakeMessengerAdapter(serviceID: "telegram")
        telegramAdapter.addMessage(convId: "c2", msgId: "tg-m1")

        let engine = PollEngine(database: db)
        engine.register(adapter: signalAdapter, config: makeConfig(service: "signal", enabled: true))
        engine.register(adapter: telegramAdapter, config: makeConfig(service: "telegram", enabled: true))

        // Disable only signal
        engine.reload(config: makeConfig(service: "signal", enabled: false))
        await engine.pollAll()

        // Signal must not have been polled; telegram must have been polled
        XCTAssertTrue(signalAdapter.fetchConfigs.isEmpty,
                      "reload(signal, enabled: false) must disable signal polling only")
        XCTAssertFalse(telegramAdapter.fetchConfigs.isEmpty,
                       "reload(signal, enabled: false) must NOT affect telegram — it must still be polled")
    }

    // MARK: - Reload toggle cycle

    func testReloadToggleDisableThenReEnableRestoresPolling() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = PollEngine(database: db)
        engine.register(adapter: adapter, config: makeConfig(enabled: true))

        // Disable
        engine.reload(config: makeConfig(enabled: false))
        await engine.pollAll()
        XCTAssertTrue(adapter.fetchConfigs.isEmpty, "Must not poll after disable")

        // Re-enable
        engine.reload(config: makeConfig(enabled: true))
        await engine.pollAll()
        XCTAssertFalse(adapter.fetchConfigs.isEmpty,
                       "After re-enabling via reload, service must resume polling — toggle must be reversible")
    }

    // MARK: - Reload updates poll interval

    func testReloadUpdatesIntervalInStoredConfig() async throws {
        // We can't observe timer fire times directly, but we can verify subsequent
        // fetch configs use the right mode after config update
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = PollEngine(database: db)
        engine.register(adapter: adapter, config: makeConfig(enabled: true, interval: 30))

        // Reload with new interval
        engine.reload(config: makeConfig(enabled: true, interval: 60))
        await engine.pollAll()

        // Just verifying the poll succeeds after interval change — the config was accepted
        XCTAssertFalse(adapter.fetchConfigs.isEmpty,
                       "Service must still be polled after reload changes the poll interval")
    }

    // MARK: - onPollSucceeded fires correctly after reload

    func testOnPollSucceededFiresForReEnabledService() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")

        let engine = PollEngine(database: db)
        engine.register(adapter: adapter, config: makeConfig(enabled: false))

        var callbackFired = false
        engine.onPollSucceeded = { callbackFired = true }

        // Disable first, add message, re-enable, poll
        adapter.addMessage(convId: "c1", msgId: "m1")
        engine.reload(config: makeConfig(enabled: true))
        await engine.pollAll()

        XCTAssertTrue(callbackFired,
                      "onPollSucceeded must fire after re-enabling a service and polling with new messages")
    }

    func testOnPollSucceededDoesNotFireForDisabledService() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = PollEngine(database: db)
        engine.register(adapter: adapter, config: makeConfig(enabled: true))

        var callbackFired = false
        engine.onPollSucceeded = { callbackFired = true }

        engine.reload(config: makeConfig(enabled: false))
        await engine.pollAll()

        XCTAssertFalse(callbackFired,
                       "onPollSucceeded must NOT fire when the service is disabled — no poll occurred")
    }
}
