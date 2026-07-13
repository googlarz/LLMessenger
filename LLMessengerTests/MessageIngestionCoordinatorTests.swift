import XCTest
import GRDB
@testable import LLMessenger

private final class IngestionTestAdapter: MessengerAdapter {
    let serviceID: String
    var healthStatus: AdapterHealthResult.Status = .ok
    var fetchCallCount = 0
    var fetchConfigs: [FetchConfig] = []
    var delayNanoseconds: UInt64 = 0
    var result: AdapterFetchResult

    init(serviceID: String = "shared", messageID: String = "m1") {
        self.serviceID = serviceID
        self.result = AdapterFetchResult(conversations: [
            AdapterConversation(
                id: "c1",
                name: "Alice",
                type: .dm,
                messages: [
                    AdapterMessage(
                        id: messageID,
                        sender: "Alice",
                        text: "Hello",
                        timestamp: Date()
                    )
                ]
            )
        ])
    }

    func start() async throws {}
    func stop() {}
    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        fetchCallCount += 1
        fetchConfigs.append(config)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return result
    }
    func send(conversationID: String, text: String) async throws {}
    func healthCheck() async -> AdapterHealthResult {
        AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil)
    }
    func listContacts() async -> [Contact] { [] }
}

private actor IngestedMessageCapture {
    private(set) var batches: [[Message]] = []

    func append(_ messages: [Message]) {
        batches.append(messages)
    }
}

final class MessageIngestionCoordinatorTests: XCTestCase {
    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    func testPersistsAndReturnsOnlyNewMessages() async throws {
        let db = try makeDB()
        let coordinator = MessageIngestionCoordinator(database: db)
        let adapter = IngestionTestAdapter()
        let config = FetchConfig(mode: .byTime(since: Date().addingTimeInterval(-60)))

        let first = try await coordinator.ingest(
            service: adapter.serviceID,
            adapter: adapter,
            config: config
        )
        let second = try await coordinator.ingest(
            service: adapter.serviceID,
            adapter: adapter,
            config: config
        )

        XCTAssertEqual(first.newMessages.map(\.messageId), ["m1"])
        XCTAssertTrue(second.newMessages.isEmpty)
        XCTAssertEqual(first.pendingMessageWatermark, second.pendingMessageWatermark)
        let count = try await db.dbQueue.read { try Message.fetchCount($0) }
        XCTAssertEqual(count, 1)
    }

    func testConcurrentMatchingRequestsShareOneFetchAndOnePublication() async throws {
        let db = try makeDB()
        let coordinator = MessageIngestionCoordinator(database: db)
        let adapter = IngestionTestAdapter()
        adapter.delayNanoseconds = 50_000_000
        let capture = IngestedMessageCapture()
        await coordinator.setNewMessagesHandler { messages in
            await capture.append(messages)
        }
        let config = FetchConfig(mode: .byTime(since: Date().addingTimeInterval(-60)))

        async let first = coordinator.ingest(
            service: adapter.serviceID,
            adapter: adapter,
            config: config
        )
        async let second = coordinator.ingest(
            service: adapter.serviceID,
            adapter: adapter,
            config: config
        )
        _ = try await (first, second)

        XCTAssertEqual(adapter.fetchCallCount, 1)
        let batches = await capture.batches
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.map(\.messageId), ["m1"])
    }

    func testBroaderRequestRunsCatchUpAfterNarrowInFlightFetch() async throws {
        let db = try makeDB()
        let coordinator = MessageIngestionCoordinator(database: db)
        let adapter = IngestionTestAdapter()
        adapter.delayNanoseconds = 50_000_000
        let narrow = FetchConfig(mode: .byTime(since: Date().addingTimeInterval(-60)))
        let broad = FetchConfig(mode: .byTime(since: Date().addingTimeInterval(-48 * 3600)))

        async let first = coordinator.ingest(
            service: adapter.serviceID,
            adapter: adapter,
            config: narrow
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        async let second = coordinator.ingest(
            service: adapter.serviceID,
            adapter: adapter,
            config: broad
        )
        _ = try await (first, second)

        XCTAssertEqual(adapter.fetchCallCount, 2)
        guard case .byTime(let secondSince) = adapter.fetchConfigs[1].mode else {
            return XCTFail("Expected broad catch-up fetch")
        }
        XCTAssertLessThan(secondSince, Date().addingTimeInterval(-47 * 3600))
    }

    @MainActor
    func testPollObservesMessagesPreviouslyInsertedByRealtimeIngestionOnce() async throws {
        let db = try makeDB()
        let coordinator = MessageIngestionCoordinator(database: db)
        let adapter = IngestionTestAdapter()
        let realtimeConfig = FetchConfig(mode: .byTime(since: Date().addingTimeInterval(-60)))
        _ = try await coordinator.ingest(
            service: adapter.serviceID,
            adapter: adapter,
            config: realtimeConfig
        )

        let engine = PollEngine(database: db, ingestionCoordinator: coordinator)
        var config = ServiceConfig.default(for: adapter.serviceID)
        config.privacyMode = PrivacyMode.eager.rawValue
        engine.register(adapter: adapter, config: config)
        var callbackCount = 0
        engine.onPollSucceeded = { callbackCount += 1 }

        try await engine.pollNow(serviceID: adapter.serviceID)
        try await engine.pollNow(serviceID: adapter.serviceID)

        XCTAssertEqual(callbackCount, 1)
    }
}
