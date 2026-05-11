import XCTest
@testable import LLMessenger

final class MockAdapter: MessengerAdapter {
    let serviceID = "mock"
    var healthStatus: AdapterHealthResult.Status = .ok

    var fetchCallCount = 0
    var fetchResult: AdapterFetchResult = AdapterFetchResult(conversations: [
        AdapterConversation(
            id: "c1", name: "Test Chat", type: .dm,
            messages: [
                AdapterMessage(id: "m1", sender: "Alice",
                               text: "Hello", timestamp: Date())
            ]
        )
    ])
    var fetchError: Error?

    func start() async throws {}
    func stop() {}

    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        fetchCallCount += 1
        if let error = fetchError { throw error }
        return fetchResult
    }

    func send(conversationID: String, text: String) async throws {}

    func healthCheck() async -> AdapterHealthResult {
        AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil)
    }
}

@MainActor final class PollEngineTests: XCTestCase {

    func testFetchStoresMessagesInDatabase() async throws {
        let db = try AppDatabase(inMemory: true)
        let mock = MockAdapter()
        let engine = PollEngine(database: db)
        engine.register(adapter: mock,
                        config: ServiceConfig.default(for: "mock"))

        try await engine.pollNow(serviceID: "mock")

        let count = try await db.dbQueue.read { db in
            try Message.fetchCount(db)
        }
        XCTAssertEqual(count, 1)
    }

    func testDeduplicatesMessages() async throws {
        let db = try AppDatabase(inMemory: true)
        let mock = MockAdapter()
        let engine = PollEngine(database: db)
        engine.register(adapter: mock,
                        config: ServiceConfig.default(for: "mock"))

        // Poll twice — same message should only be stored once
        try await engine.pollNow(serviceID: "mock")
        try await engine.pollNow(serviceID: "mock")

        let count = try await db.dbQueue.read { db in try Message.fetchCount(db) }
        XCTAssertEqual(count, 1)
    }

    func testUpdatesHealthOnFailure() async throws {
        let db = try AppDatabase(inMemory: true)
        let mock = MockAdapter()
        mock.fetchError = AdapterError.notRunning
        let engine = PollEngine(database: db)
        engine.register(adapter: mock,
                        config: ServiceConfig.default(for: "mock"))

        try? await engine.pollNow(serviceID: "mock")

        let health = try await db.dbQueue.read { db in
            try ServiceHealth.fetchOne(db, key: "mock")
        }
        XCTAssertEqual(health?.status, "error")
        XCTAssertEqual(engine.failureCounts["mock"], 1)
    }

    // MARK: - Disabled service skipping

    func testDisabledServiceIsSkippedDuringPollAll() async throws {
        let db = try AppDatabase(inMemory: true)
        let mock = MockAdapter()
        let engine = PollEngine(database: db)

        var config = ServiceConfig.default(for: "mock")
        config.enabled = false
        engine.register(adapter: mock, config: config)

        await engine.pollAll()

        XCTAssertEqual(mock.fetchCallCount, 0, "fetch() must not be called for a disabled service")
    }

    // MARK: - Retry-start on unhealthy adapter

    func testRetryStartAttemptedWhenAdapterHealthIsNotOk() async throws {
        let db = try AppDatabase(inMemory: true)

        // Adapter that fails start() once, then succeeds.
        let retryMock = RetryStartMockAdapter()
        let engine = PollEngine(database: db)
        engine.register(adapter: retryMock, config: ServiceConfig.default(for: "retry"))

        // Simulate adapter in failed state (as if start() threw during engine.start()).
        retryMock.healthStatus = .error

        // First pollNow: start() should be retried.
        try? await engine.pollNow(serviceID: "retry")

        XCTAssertEqual(retryMock.startCallCount, 1, "pollOnce must retry start() when healthStatus != .ok")
    }

    func testRetryStartSucceedsAndFetchRunsAfterRecovery() async throws {
        let db = try AppDatabase(inMemory: true)
        let retryMock = RetryStartMockAdapter()
        retryMock.healthStatus = .error   // start as failed
        retryMock.startShouldSucceed = true

        let engine = PollEngine(database: db)
        engine.register(adapter: retryMock, config: ServiceConfig.default(for: "retry"))

        try? await engine.pollNow(serviceID: "retry")

        XCTAssertEqual(retryMock.startCallCount, 1)
        XCTAssertEqual(retryMock.fetchCallCount, 1, "fetch() must run after successful retry-start")
    }

    // MARK: - First-run 24h window

    func testFirstRunFetchWindowIs48Hours() async throws {
        let db = try AppDatabase(inMemory: true)

        // Capture the FetchConfig passed to the adapter.
        let capturingMock = CapturingFetchMockAdapter()
        let engine = PollEngine(database: db)
        // Use .time fetch mode so makeFetchConfig takes the time branch.
        var config = ServiceConfig.default(for: "capturing")
        config.fetchMode = FetchMode.time.rawValue
        engine.register(adapter: capturingMock, config: config)

        let before = Date()
        try? await engine.pollNow(serviceID: "capturing")
        let after = Date()

        let captured = try XCTUnwrap(capturingMock.lastConfig)
        guard case .byTime(let since) = captured.mode else {
            XCTFail("Expected .byTime fetch mode"); return
        }

        let age = before.timeIntervalSince(since)
        XCTAssertGreaterThan(age, 47 * 3600, "First-run window must be ≥ 47 hours (got \(age / 3600)h)")
        XCTAssertLessThan(age, 49 * 3600 + after.timeIntervalSince(before),
                          "First-run window must be ≤ 49 hours")
    }
}

// MARK: - Additional mock adapters

final class RetryStartMockAdapter: MessengerAdapter {
    let serviceID = "retry"
    var healthStatus: AdapterHealthResult.Status = .ok
    var startCallCount = 0
    var startShouldSucceed = true
    var fetchCallCount = 0

    func start() async throws {
        startCallCount += 1
        if startShouldSucceed {
            healthStatus = .ok
        } else {
            throw AdapterError.initFailed("Simulated start failure")
        }
    }
    func stop() { healthStatus = .warning }
    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        fetchCallCount += 1
        return AdapterFetchResult(conversations: [])
    }
    func send(conversationID: String, text: String) async throws {}
    func healthCheck() async -> AdapterHealthResult {
        AdapterHealthResult(status: healthStatus, reason: nil, retryAfter: nil)
    }
}

final class CapturingFetchMockAdapter: MessengerAdapter {
    let serviceID = "capturing"
    var healthStatus: AdapterHealthResult.Status = .ok
    var lastConfig: FetchConfig?

    func start() async throws { healthStatus = .ok }
    func stop() {}
    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        lastConfig = config
        return AdapterFetchResult(conversations: [])
    }
    func send(conversationID: String, text: String) async throws {}
    func healthCheck() async -> AdapterHealthResult {
        AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil)
    }
}
