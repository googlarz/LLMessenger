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
}
