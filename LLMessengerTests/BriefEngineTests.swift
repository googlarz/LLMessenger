// LLMessengerTests/BriefEngineTests.swift
import XCTest
@testable import LLMessenger

// Valid JSON the BriefEngine expects: cards array with at least one card.
private let validBriefJSON = """
{
  "total_messages": 3,
  "total_threads": 1,
  "total_people": 1,
  "cards": [
    {
      "id": "telegram-c1-1",
      "service": "telegram",
      "conversationId": "c1",
      "conversationTitle": "c1",
      "headline": "Test headline",
      "priority": "high",
      "counts": {"messages": 3, "threads": 1, "people": 1},
      "summary": "Alice sent test messages.",
      "callback": null,
      "actionItems": ["Reply to Alice."],
      "quotes": [
        {"messageId": "m0", "from": "Alice", "time": "09:00", "text": "msg 0"}
      ],
      "sourceMessageIds": ["m0"]
    }
  ]
}
"""

private let noSourceBriefJSON = """
{
  "total_messages": 1,
  "total_threads": 1,
  "total_people": 1,
  "cards": [
    {
      "id": "telegram-c1-1",
      "service": "telegram",
      "conversationId": "c1",
      "conversationTitle": "c1",
      "headline": "No source",
      "priority": "low",
      "counts": {"messages": 1, "threads": 1, "people": 1},
      "summary": "This card cannot be trusted.",
      "callback": null,
      "actionItems": [],
      "quotes": [],
      "sourceMessageIds": []
    }
  ]
}
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

    func testProcessNewMessagesIncludesMessageIdsInPrompt() async throws {
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 2)
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: validBriefJSON, inputTokens: 10, outputTokens: 5)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        let userPrompt = try XCTUnwrap(mock.calls.last?.messages.last?.content)
        XCTAssertTrue(userPrompt.contains("=== c1 |"))
        XCTAssertTrue(userPrompt.contains("[id=m0 |"))
        XCTAssertTrue(userPrompt.contains("[id=m1 |"))
    }

    func testProcessNewMessagesStoresBriefCardsAndSources() async throws {
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 3)
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: validBriefJSON, inputTokens: 10, outputTokens: 5)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        let repo = BriefRepository(database: db)
        let cards = try repo.fetchBriefCards(briefID: try XCTUnwrap(id))
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].id, "telegram-c1-1")
        XCTAssertEqual(cards[0].sourceMessageIds, #"["m0"]"#)

        let sources = try repo.fetchSources(briefCardID: "telegram-c1-1")
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].messageId, "m0")
        XCTAssertEqual(sources[0].sourceRole, BriefCardSourceRole.quote.rawValue)
        XCTAssertNotNil(sources[0].messageRowId)
    }

    func testProcessNewMessagesIncludesRollingSummaryAndRecentContext() async throws {
        let db = try setupDB()
        let repo = BriefRepository(database: db)
        try await db.dbQueue.write { db in
            var oldBrief = Brief(
                createdAt: Date(timeIntervalSince1970: 50),
                status: "ready",
                services: #"["telegram"]"#,
                openingSummary: nil,
                notificationText: "old",
                episodicSummary: nil
            )
            try oldBrief.insert(db)

            var oldMessage = Message(
                briefId: oldBrief.id,
                service: "telegram",
                conversationId: "c1",
                conversationName: "Joanna",
                messageId: "m-old",
                sender: "Joanna",
                text: "Earlier context",
                timestamp: Date(timeIntervalSince1970: 110),
                isSent: false
            )
            try oldMessage.insert(db)

            for i in 0..<2 {
                var msg = Message(
                    briefId: nil,
                    service: "telegram",
                    conversationId: "c1",
                    conversationName: "Joanna",
                    messageId: "m\(i)",
                    sender: "Alice",
                    text: "msg \(i)",
                    timestamp: Date(timeIntervalSince1970: Double(120 + i)),
                    isSent: false
                )
                try msg.insert(db)
            }
        }
        try repo.upsertConversationState(
            ConversationState(
                service: "telegram",
                conversationId: "c1",
                lastSeenMessageId: "m-old",
                lastSummarizedMessageId: "m-old",
                rollingSummary: "Previously Joanna was checking timing.",
                participants: #"["Joanna"]"#,
                knownEntities: nil,
                unresolvedActions: nil,
                lastBriefCardId: nil,
                prioritySignals: nil,
                sourceMessageIds: #"["m-old"]"#,
                updatedAt: Date()
            )
        )
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: validBriefJSON, inputTokens: 10, outputTokens: 5)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        let userPrompt = try XCTUnwrap(mock.calls.last?.messages.last?.content)
        XCTAssertTrue(userPrompt.contains("Previous summary: Previously Joanna was checking timing."))
        XCTAssertTrue(userPrompt.contains("[Recent context before new messages]"))
        XCTAssertTrue(userPrompt.contains("Earlier context"))
    }

    func testProcessNewMessagesIncludesUnresolvedActions() async throws {
        let db = try setupDB()
        let repo = BriefRepository(database: db)
        try await db.dbQueue.write { db in
            var msg = Message(
                briefId: nil, service: "telegram", conversationId: "c1",
                messageId: "m-new", sender: "Alice", text: "New message",
                timestamp: Date(), isSent: false
            )
            try msg.insert(db)
        }
        try repo.upsertConversationState(
            ConversationState(
                service: "telegram",
                conversationId: "c1",
                lastSeenMessageId: "m-old",
                lastSummarizedMessageId: "m-old",
                rollingSummary: "Old summary",
                participants: #"["Alice"]"#,
                unresolvedActions: #"["Buy milk"]"#,
                updatedAt: Date()
            )
        )
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: validBriefJSON, inputTokens: 10, outputTokens: 5)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        let userPrompt = try XCTUnwrap(mock.calls.last?.messages.last?.content)
        XCTAssertTrue(userPrompt.contains("Unresolved actions from prior brief: [\"Buy milk\"]"))
    }

    func testProcessNewMessagesPersistsConversationState() async throws {
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 3)
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: validBriefJSON, inputTokens: 10, outputTokens: 5)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        let repo = BriefRepository(database: db)
        let state = try repo.fetchConversationState(service: "telegram", conversationID: "c1")
        XCTAssertEqual(state?.rollingSummary, "Alice sent test messages.")
        XCTAssertEqual(state?.lastSummarizedMessageId, "m2")
        XCTAssertEqual(state?.lastBriefCardId, "telegram-c1-1")
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

    func testProcessNewMessagesRejectsCardsWithoutSources() async throws {
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 2)
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: noSourceBriefJSON, inputTokens: 5, outputTokens: 2)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        XCTAssertNil(id)
        let repo = BriefRepository(database: db)
        let stillUnattached = try repo.fetchUnattachedMessages()
        XCTAssertEqual(stillUnattached.count, 2)
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
