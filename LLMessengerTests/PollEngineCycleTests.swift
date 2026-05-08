// LLMessengerTests/PollEngineCycleTests.swift
// Tests PollEngine — the real entry point for all production messages.
// PollEngine is the only major subsystem with no integration tests.
// These tests cover: message storage, deduplication, first-run fetch window,
// health tracking, failure counting, disabled service skipping, in-flight guard,
// and the onPollSucceeded callback contract.
import XCTest
import GRDB
@testable import LLMessenger

// MARK: - FakeMessengerAdapter

final class FakeMessengerAdapter: MessengerAdapter {
    let serviceID: String
    var healthStatus: AdapterHealthResult.Status = .ok
    var shouldFailStart = false
    var shouldFailFetch = false
    var conversations: [AdapterConversation] = []
    private(set) var startCallCount = 0
    private(set) var fetchConfigs: [FetchConfig] = []

    init(serviceID: String) { self.serviceID = serviceID }

    func start() async throws {
        startCallCount += 1
        if shouldFailStart {
            healthStatus = .error
            throw AdapterError.initFailed("Simulated start failure")
        }
        healthStatus = .ok
    }

    func stop() {}

    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        fetchConfigs.append(config)
        if shouldFailFetch { throw AdapterError.invalidResponse }
        return AdapterFetchResult(conversations: conversations)
    }

    func send(conversationID: String, text: String) async throws {}
    func healthCheck() async -> AdapterHealthResult {
        AdapterHealthResult(status: healthStatus, reason: nil, retryAfter: nil)
    }

    // Helpers for building test data
    func addMessage(convId: String, convName: String = "Conv",
                    msgId: String, sender: String = "Alice",
                    text: String = "Hi", at date: Date = Date()) {
        let msg = AdapterMessage(id: msgId, sender: sender, text: text, timestamp: date)
        if let i = conversations.firstIndex(where: { $0.id == convId }) {
            var msgs = conversations[i].messages
            msgs.append(msg)
            conversations[i] = AdapterConversation(id: convId, name: convName,
                                                    type: .dm, messages: msgs)
        } else {
            conversations.append(AdapterConversation(id: convId, name: convName,
                                                      type: .dm, messages: [msg]))
        }
    }
}

// MARK: - PollEngineCycleTests

@MainActor
final class PollEngineCycleTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func makeEngine(db: AppDatabase) -> PollEngine { PollEngine(database: db) }

    private func signalConfig(enabled: Bool = true) -> ServiceConfig {
        ServiceConfig(service: "signal", enabled: enabled,
                      pollIntervalMinutes: 30, fetchMode: "time",
                      fetchLimit: 50, privacyMode: "eager")
    }

    // MARK: - Message storage

    func testPollAllStoresMessagesFromAdapter() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())
        await engine.pollAll()

        let count = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(count, 1, "pollAll must store messages returned by the adapter")
    }

    // MARK: - Deduplication

    func testDuplicateMessageIdIsIgnoredOnSecondPoll() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())

        // Two polls, same message each time
        await engine.pollAll()
        await engine.pollAll()

        let count = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(count, 1, "Duplicate messageId must be ignored — INSERT OR IGNORE deduplicates")
    }

    func testNewMessageOnSecondPollIsStored() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())
        await engine.pollAll()

        adapter.addMessage(convId: "c1", msgId: "m2")
        await engine.pollAll()

        let count = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(count, 2, "New message on second poll must be stored alongside the first")
    }

    // MARK: - First-run fetch window

    func testFirstRunFetchConfigUsesTimeMode() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())
        await engine.pollAll()

        let config = try XCTUnwrap(adapter.fetchConfigs.first, "Adapter must have been called")
        if case .byTime(let since) = config.mode {
            let windowSeconds = Date().timeIntervalSince(since)
            XCTAssertGreaterThan(windowSeconds, 23 * 3600,
                                 "First-run fetch window must be ~24 hours so recent messages aren't missed")
        } else {
            XCTFail("First-run fetch config must use .byTime mode")
        }
    }

    func testSubsequentPollUsesLastCheckTimestamp() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())

        let before = Date()
        await engine.pollAll()       // first poll — writes ServiceHealth.lastCheck
        await engine.pollAll()       // second poll — should use lastCheck as since

        XCTAssertEqual(adapter.fetchConfigs.count, 2)
        if case .byTime(let since) = adapter.fetchConfigs[1].mode {
            XCTAssertGreaterThanOrEqual(since, before.addingTimeInterval(-5),
                                        "Second poll must use lastCheck timestamp as fetch window start")
            let windowSeconds = Date().timeIntervalSince(since)
            XCTAssertLessThan(windowSeconds, 3600,
                              "Second poll must NOT use the 24h first-run window — it has a lastCheck timestamp")
        } else {
            XCTFail("Second poll fetch config must use .byTime mode")
        }
    }

    // MARK: - ServiceHealth tracking

    func testSuccessfulPollWritesOkHealth() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())
        await engine.pollAll()

        let health = try await db.dbQueue.read { d in
            try ServiceHealth.fetchOne(d, key: "signal")
        }
        XCTAssertEqual(health?.status, "ok", "Successful poll must write 'ok' health status")
        XCTAssertNotNil(health?.lastCheck, "Successful poll must record lastCheck timestamp")
        XCTAssertNil(health?.lastError, "Successful poll must clear lastError")
    }

    func testFetchFailureWritesErrorHealthAndIncrementsFailureCount() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.shouldFailFetch = true

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())
        await engine.pollAll()

        let health = try await db.dbQueue.read { d in
            try ServiceHealth.fetchOne(d, key: "signal")
        }
        XCTAssertEqual(health?.status, "error", "Failed poll must write 'error' health status")
        XCTAssertNotNil(health?.lastError, "Failed poll must record lastError message")
        XCTAssertEqual(engine.failureCounts["signal"], 1,
                       "Failure count must increment on each poll failure")
    }

    func testSuccessAfterFailureResetsFailureCount() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())

        adapter.shouldFailFetch = true
        await engine.pollAll()
        XCTAssertEqual(engine.failureCounts["signal"], 1)

        adapter.shouldFailFetch = false
        adapter.addMessage(convId: "c1", msgId: "m1")
        await engine.pollAll()
        XCTAssertEqual(engine.failureCounts["signal"], 0,
                       "Failure count must reset to 0 after a successful poll")
    }

    // MARK: - Disabled service

    func testDisabledServiceIsSkippedInPollAll() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig(enabled: false))
        await engine.pollAll()

        XCTAssertTrue(adapter.fetchConfigs.isEmpty,
                      "Disabled service must not be polled — fetch must not be called")
        let count = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(count, 0)
    }

    // MARK: - In-flight guard

    func testConcurrentPollsForSameServiceAreDeduplicatedByInFlightGuard() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())

        // Two simultaneous pollAll calls
        async let first  = engine.pollAll()
        async let second = engine.pollAll()
        await (first, second)

        // In-flight guard must prevent double-fetch
        XCTAssertEqual(adapter.fetchConfigs.count, 1,
                       "In-flight guard must prevent two simultaneous fetches for the same service")
    }

    // MARK: - onPollSucceeded callback

    func testOnPollSucceededFiresWhenNewMessagesArrived() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())

        var callbackFired = false
        engine.onPollSucceeded = { callbackFired = true }

        await engine.pollAll()

        XCTAssertTrue(callbackFired,
                      "onPollSucceeded must fire when new messages were stored — this triggers brief generation")
    }

    func testOnPollSucceededDoesNotFireWhenNoNewMessages() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        // Adapter returns no messages

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())

        var callbackFired = false
        engine.onPollSucceeded = { callbackFired = true }

        await engine.pollAll()

        XCTAssertFalse(callbackFired,
                       "onPollSucceeded must NOT fire when adapter returns no new messages")
    }

    func testOnPollSucceededDoesNotFireForDuplicateMessages() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let engine = makeEngine(db: db)
        engine.register(adapter: adapter, config: signalConfig())

        // First poll — fires callback
        var firstFired = false
        engine.onPollSucceeded = { firstFired = true }
        await engine.pollAll()
        XCTAssertTrue(firstFired)

        // Second poll with same messages — must not fire again
        var secondFired = false
        engine.onPollSucceeded = { secondFired = true }
        await engine.pollAll()

        XCTAssertFalse(secondFired,
                       "onPollSucceeded must NOT fire on second poll when all messages are duplicates")
    }
}
