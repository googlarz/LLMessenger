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
        // Header now includes [service] tag: === [telegram] c1 | Title ===
        XCTAssertTrue(userPrompt.contains("=== [telegram] c1 |"))
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
        XCTAssertEqual(cards[0].sourceMessageIds, #"["m0"]"#)

        let sources = try repo.fetchSources(briefCardID: cards[0].id)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].messageId, "m0")
        XCTAssertEqual(sources[0].sourceRole, BriefCardSourceRole.quote.rawValue)
        XCTAssertNotNil(sources[0].messageRowId)
    }

    func testProcessNewMessagesIncludesRollingSummaryAndRecentContext() async throws {
        let db = try setupDB()
        let repo = BriefRepository(database: db)
        let now = Date()
        try await db.dbQueue.write { db in
            var oldBrief = Brief(
                createdAt: now.addingTimeInterval(-3600),
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
                timestamp: now.addingTimeInterval(-1800),
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
                    timestamp: now.addingTimeInterval(Double(-60 + i)),
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

    // MARK: - Conversation block header format

    func testConversationBlockHeaderIncludesServiceTag() async throws {
        // The [service] tag is required so the LLM can extract service and conversationId
        // independently. Without it, the LLM guessed service from the opaque ID format.
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 1)   // service="telegram", conversationId="c1"
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: validBriefJSON, inputTokens: 10, outputTokens: 5)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        let userPrompt = try XCTUnwrap(mock.calls.last?.messages.last?.content)
        XCTAssertTrue(userPrompt.contains("=== [telegram] c1 |"),
                      "Block header must be '=== [telegram] c1 | …' — got:\n\(userPrompt)")
    }

    func testConversationBlockMessageLineFormat() async throws {
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 1)
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: validBriefJSON, inputTokens: 10, outputTokens: 5)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        let userPrompt = try XCTUnwrap(mock.calls.last?.messages.last?.content)
        // Message line must start with [id=<id> | <time>] Sender: text
        XCTAssertTrue(userPrompt.contains("[id=m0 |"), "Message line must start with [id=<id> |")
        XCTAssertTrue(userPrompt.contains("] Alice:"), "Message line must contain '] Sender:'")
    }

    func testMultiServiceEachGetsItsOwnLLMCall() async throws {
        // BriefEngine makes one LLM call per service (parallel TaskGroup).
        // Verify that telegram and signal each get their own prompt with the correct service block.
        let db = try setupDB()
        try await db.dbQueue.write { db in
            let cfg = ServiceConfig.default(for: "signal")
            try cfg.insert(db)
        }
        try await db.dbQueue.write { db in
            var m1 = Message(briefId: nil, service: "telegram", conversationId: "c1",
                             messageId: "t1", sender: "Bob", text: "telegram msg",
                             timestamp: Date(), isSent: false)
            var m2 = Message(briefId: nil, service: "signal", conversationId: "s1",
                             messageId: "s1", sender: "Alice", text: "signal msg",
                             timestamp: Date(), isSent: false)
            try m1.insert(db)
            try m2.insert(db)
        }

        // Service-aware mock: returns service-specific valid JSON based on which service
        // is mentioned in the system prompt.
        let mock = ServiceAwareMockLLMClient()
        mock.jsonForService["telegram"] = """
        {"total_messages":1,"total_threads":1,"total_people":1,"cards":[
          {"id":"telegram-c1-1","service":"telegram","conversationId":"c1",
           "conversationTitle":"Bob","headline":"Bob said hi","priority":"low",
           "counts":{"messages":1,"threads":1,"people":1},"summary":"Bob said hi.",
           "callback":null,"actionItems":[],"quotes":[],"sourceMessageIds":["t1"]}
        ]}
        """
        mock.jsonForService["signal"] = """
        {"total_messages":1,"total_threads":1,"total_people":1,"cards":[
          {"id":"signal-s1-1","service":"signal","conversationId":"s1",
           "conversationTitle":"Alice","headline":"Alice said hi","priority":"low",
           "counts":{"messages":1,"threads":1,"people":1},"summary":"Alice said hi.",
           "callback":null,"actionItems":[],"quotes":[],"sourceMessageIds":["s1"]}
        ]}
        """

        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")
        _ = try await engine.processNewMessages()

        // Two separate LLM calls must be made.
        XCTAssertEqual(mock.calls.count, 2, "BriefEngine must make one LLM call per service")

        // Each call's user prompt must contain only that service's conversation block.
        let telegramCall = mock.calls.first { $0.messages.first?.content.contains("Connected services: telegram") ?? false }
        let signalCall   = mock.calls.first { $0.messages.first?.content.contains("Connected services: signal") ?? false }

        XCTAssertNotNil(telegramCall, "Must have a call for telegram")
        XCTAssertNotNil(signalCall,   "Must have a call for signal")

        let telegramPrompt = telegramCall?.messages.last?.content ?? ""
        let signalPrompt   = signalCall?.messages.last?.content   ?? ""

        XCTAssertTrue(telegramPrompt.contains("=== [telegram] c1 |"), "Telegram call must contain telegram block")
        XCTAssertTrue(signalPrompt.contains("=== [signal] s1 |"),     "Signal call must contain signal block")
    }

    // MARK: - JSON fence / truncation robustness

    func testBriefEngineHandlesTruncatedJSON() async throws {
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 1)
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: #"{"cards":[{"id":"x","headl"#, inputTokens: 5, outputTokens: 2)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        XCTAssertNil(id, "Truncated JSON must produce nil (no brief), not a crash")
    }

    func testBriefEngineStripsMarkdownFencesAndSucceeds() async throws {
        // LLMs sometimes wrap JSON output in ```json … ``` fences.
        // BriefEngine strips fences before parsing, so a brief should still be produced.
        let db = try setupDB()
        try insertUnattachedMessages(db, count: 1)
        let mock = MockLLMClient()
        mock.response = LLMResponse(
            text: "```json\n\(validBriefJSON)\n```",
            inputTokens: 5, outputTokens: 2
        )
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        XCTAssertNotNil(id, "BriefEngine must strip markdown fences and still produce a brief")
    }

    /// Regression: if the LLM cites a context message ID (from a previously-briefed message
    /// shown as recent context), the card was incorrectly rejected because the context message
    /// was not in the `sourceMessages` allowlist (which only contained unattached messages).
    func testProcessNewMessagesAcceptsContextMessageIdInSourceMessageIds() async throws {
        let db = try setupDB()
        // Insert a previously-briefed context message (briefId set → not unattached).
        var contextMsgBriefId: Int64 = 0
        try await db.dbQueue.write { db in
            var brief = Brief(createdAt: Date(timeIntervalSinceNow: -7200),
                              status: "ready", services: "[\"telegram\"]",
                              openingSummary: nil, notificationText: "old",
                              episodicSummary: nil)
            try brief.insert(db)
            contextMsgBriefId = brief.id!
            var ctxMsg = Message(briefId: contextMsgBriefId, service: "telegram",
                                 conversationId: "c1", messageId: "ctx_msg_id",
                                 sender: "Alice", text: "Earlier message (context)",
                                 timestamp: Date(timeIntervalSinceNow: -3600), isSent: false)
            try ctxMsg.insert(db)
        }
        // Insert the new unattached message in the same conversation.
        try await db.dbQueue.write { db in
            var newMsg = Message(briefId: nil, service: "telegram",
                                 conversationId: "c1", messageId: "new_msg_id",
                                 sender: "Alice", text: "Reply to earlier",
                                 timestamp: Date(), isSent: false)
            try newMsg.insert(db)
        }
        // LLM response cites the context message ID in sourceMessageIds — this was the bug.
        let briefCitingContext = """
        {
          "total_messages": 2, "total_threads": 1, "total_people": 1,
          "cards": [{
            "id": "telegram-c1-1", "service": "telegram",
            "conversationId": "c1", "conversationTitle": "c1",
            "headline": "Alice sent a follow-up",
            "priority": "med",
            "counts": {"messages": 2, "threads": 1, "people": 1},
            "summary": "Alice replied to her earlier message.",
            "callback": null, "actionItems": [],
            "quotes": [],
            "sourceMessageIds": ["ctx_msg_id", "new_msg_id"]
          }]
        }
        """
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: briefCitingContext, inputTokens: 5, outputTokens: 10)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        XCTAssertNotNil(id,
            "Brief must be created even when LLM cites a context (already-briefed) message ID in sourceMessageIds")
    }
}

// Service-aware mock: returns service-specific JSON based on which service appears in the system prompt.
final class ServiceAwareMockLLMClient: LLMClient {
    var calls: [(model: String, messages: [LLMMessage], maxTokens: Int)] = []
    var jsonForService: [String: String] = [:]
    var fallbackJSON: String = #"{"cards":[]}"#

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        calls.append((model, messages, maxTokens))
        let systemContent = messages.first(where: { $0.role == .system })?.content ?? ""
        let service = ["signal", "telegram", "imessage"].first { systemContent.contains($0) } ?? ""
        let text = jsonForService[service] ?? fallbackJSON
        return LLMResponse(text: text, inputTokens: 10, outputTokens: 5)
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
