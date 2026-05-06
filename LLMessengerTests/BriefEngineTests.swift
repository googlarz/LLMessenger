// LLMessengerTests/BriefEngineTests.swift
import XCTest
@testable import LLMessenger

// Valid JSON the BriefEngine expects: cards array with at least one card.
private let validBriefJSON = """
{"total_messages":3,"total_threads":1,"total_people":1,"cards":[{"headline":"Test headline"}]}
"""

@MainActor
final class BriefEngineTests: XCTestCase {

    func setupDB() throws -> AppDatabase {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            let cfg = ServiceConfig.default(for: "telegram")
            try cfg.insert(db)
        }
        return db
    }

    func insertUnattachedMessages(_ db: AppDatabase, count: Int) throws {
        try db.dbQueue.write { db in
            for i in 0..<count {
                var msg = Message(briefId: nil, service: "telegram",
                                  conversationId: "c1", messageId: "m\(i)",
                                  sender: "Alice", text: "msg \(i)",
                                  timestamp: Date(), isSent: false)
                try msg.insert(db)
            }
        }
    }

    func testNoUnattachedMessagesCreatesNoBrief() async throws {
        let db = try setupDB()
        let mock = MockLLMClient()
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        XCTAssertNil(id)
        XCTAssertEqual(mock.calls.count, 0)
    }

    func testProcessNewMessagesCreatesBriefWithLLMCall() async throws {
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 3)
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: validBriefJSON, inputTokens: 10, outputTokens: 5)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        XCTAssertNotNil(id)
        XCTAssertEqual(mock.calls.count, 1)

        let repo = BriefRepository(database: db)
        let brief = try repo.fetchBrief(id: id!)!
        XCTAssertNotNil(brief.openingSummary)
        XCTAssertTrue(brief.notificationText.contains("3"))
    }

    func testProcessNewMessagesReturnsNilWhenLLMReturnsNoCards() async throws {
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 2)
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "not valid json", inputTokens: 5, outputTokens: 2)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        XCTAssertNil(id)
    }

    func testCompressesPreviousBriefBeforeCreatingNewOne() async throws {
        let db = try setupDB()
        var prevId: Int64 = 0
        try await db.dbQueue.write { db in
            var prev = Brief(createdAt: Date(timeIntervalSinceNow: -3600),
                             status: "idle", services: "[\"telegram\"]",
                             openingSummary: nil, notificationText: "x",
                             episodicSummary: nil)
            try prev.insert(db)
            prevId = prev.id!
            var msg = Message(briefId: prevId, service: "telegram",
                              conversationId: "c0", messageId: "m_old",
                              sender: "Bob", text: "old message",
                              timestamp: Date(timeIntervalSinceNow: -3600),
                              isSent: false)
            try msg.insert(db)
        }
        try insertUnattachedMessages(db, count: 1)

        let mock = MockLLMClient()
        // First call: compression (returns episodic text); second call: summarization (returns JSON).
        var callIndex = 0
        mock.response = LLMResponse(text: validBriefJSON, inputTokens: 5, outputTokens: 3)
        // Override by checking calls: compression must happen first.
        // Use two sequential responses via a custom closure is not supported by MockLLMClient,
        // so we verify call count and episodicSummary is set after both calls complete.
        _ = mock  // suppress unused warning

        let compressionMock = TwoStageMockLLMClient(
            first: "Bob talked about old stuff.",
            second: validBriefJSON
        )
        let engine = BriefEngine(database: db, client: compressionMock, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        XCTAssertEqual(compressionMock.calls.count, 2)
        let repo = BriefRepository(database: db)
        let prev = try repo.fetchBrief(id: prevId)!
        XCTAssertEqual(prev.episodicSummary, "Bob talked about old stuff.")
    }

    func testAttachesMessagesToNewBrief() async throws {
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 4)
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: validBriefJSON, inputTokens: 10, outputTokens: 5)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        XCTAssertNotNil(id)
        let repo = BriefRepository(database: db)
        let attached = try repo.fetchMessages(forBriefID: id!)
        XCTAssertEqual(attached.count, 4)

        let stillUnattached = try repo.fetchUnattachedMessages()
        XCTAssertEqual(stillUnattached.count, 0)
    }
}

// Two-stage mock: returns `first` on call 1, `second` on call 2+.
final class TwoStageMockLLMClient: LLMClient {
    var calls: [(model: String, messages: [LLMMessage], maxTokens: Int)] = []
    private let first: String
    private let second: String

    init(first: String, second: String) {
        self.first = first
        self.second = second
    }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        calls.append((model, messages, maxTokens))
        let text = calls.count == 1 ? first : second
        return LLMResponse(text: text, inputTokens: 5, outputTokens: 3)
    }
}
