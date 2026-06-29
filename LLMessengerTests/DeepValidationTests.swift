// LLMessengerTests/DeepValidationTests.swift
// Deep tests for validation logic, context windows, adapter fallbacks,
// conversation state carry-forward, and compression error handling.
import XCTest
import GRDB
@testable import LLMessenger

// MARK: - Helpers

private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

@MainActor
private func makeBriefEngine(db: AppDatabase, mock: LLMClient) -> BriefEngine {
    BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")
}

private func insertMessages(
    db: AppDatabase,
    service: String = "signal",
    convId: String = "c1",
    convName: String? = nil,
    messageIds: [String],
    sender: String = "Alice",
    baseTime: Date = Date(),
    intervalSeconds: Double = 1,
    briefId: Int64? = nil
) async throws {
    try await db.dbQueue.write { d in
        for (i, msgId) in messageIds.enumerated() {
            var m = Message(
                briefId: briefId,
                service: service,
                conversationId: convId,
                conversationName: convName,
                messageId: msgId,
                sender: sender,
                text: "Message \(msgId)",
                timestamp: baseTime.addingTimeInterval(Double(i) * intervalSeconds),
                isSent: false
            )
            try m.insert(d)
        }
    }
}

// MARK: - Validation Edge Cases

@MainActor
final class ValidationEdgeCaseTests: XCTestCase {

    // Quote references a messageId that exists in the DB but is NOT in sourceMessageIds.
    // The validation code filters quotes against sourceIDs (all messages for the service),
    // so this quote should survive as long as the messageId exists in the source messages.
    func testQuoteReferencingKnownMessageIdSurvives() async throws {
        let db = try makeDB()
        let now = Date()
        try await insertMessages(db: db, messageIds: ["m1", "m2"], baseTime: now)

        let json = """
        {"cards":[{"id":"signal-c1-1","service":"signal","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":2,"threads":1,"people":1},
        "sourceMessageIds":["m1","m2"],
        "quotes":[{"messageId":"m2","from":"Alice","time":"10:00","text":"Message m2"}]}]}
        """
        let mock = RiggedMock(json)
        let engine = makeBriefEngine(db: db, mock: mock)
        let result = try await engine.processNewMessages()

        XCTAssertNotNil(result, "Card with valid quote referencing a known messageId must succeed")
        let repo = BriefRepository(database: db)
        let cards = try repo.fetchBriefCards(briefID: result!)
        let sources = try repo.fetchSources(briefCardID: cards[0].id)
        let quoteSource = sources.first { $0.sourceRole == BriefCardSourceRole.quote.rawValue }
        XCTAssertNotNil(quoteSource, "Quote source must be persisted")
        XCTAssertEqual(quoteSource?.messageId, "m2")
    }

    // Quote references a messageId that does NOT exist in the DB at all.
    // Should be dropped from the card's quotes but the card should still survive
    // (because sourceMessageIds are valid).
    func testQuoteWithHallucinatedIdIsDroppedButCardSurvives() async throws {
        let db = try makeDB()
        try await insertMessages(db: db, messageIds: ["m1"])

        let json = """
        {"cards":[{"id":"signal-c1-1","service":"signal","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":1,"threads":1,"people":1},
        "sourceMessageIds":["m1"],
        "quotes":[{"messageId":"hallucinated-99","from":"Ghost","time":"10:00","text":"Fake"}]}]}
        """
        let mock = RiggedMock(json)
        let engine = makeBriefEngine(db: db, mock: mock)
        let result = try await engine.processNewMessages()

        XCTAssertNotNil(result, "Card must survive even if its quotes reference unknown messageIds")
        let repo = BriefRepository(database: db)
        let cards = try repo.fetchBriefCards(briefID: result!)
        let sources = try repo.fetchSources(briefCardID: cards[0].id)
        XCTAssertTrue(sources.allSatisfy { $0.sourceRole == BriefCardSourceRole.newMessage.rawValue },
                      "No quote source should be persisted for a hallucinated messageId")
    }

    // All sourceMessageIds are hallucinated — card is dropped entirely.
    func testAllHallucinatedSourceIdsRejectsCard() async throws {
        let db = try makeDB()
        try await insertMessages(db: db, messageIds: ["m1"])

        let json = """
        {"cards":[{"id":"signal-c1-1","service":"signal","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":1,"threads":1,"people":1},
        "sourceMessageIds":["fake1","fake2"]}]}
        """
        let mock = RiggedMock(json)
        let engine = makeBriefEngine(db: db, mock: mock)
        let result = try await engine.processNewMessages()

        XCTAssertNil(result, "Card with only hallucinated sourceMessageIds must be rejected")
    }

    // Card claims wrong service — should be dropped.
    func testWrongServiceCardIsDropped() async throws {
        let db = try makeDB()
        try await insertMessages(db: db, service: "signal", messageIds: ["m1"])

        let json = """
        {"cards":[{"id":"t-c1-1","service":"telegram","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":1,"threads":1,"people":1},
        "sourceMessageIds":["m1"]}]}
        """
        let mock = RiggedMock(json)
        let engine = makeBriefEngine(db: db, mock: mock)
        let result = try await engine.processNewMessages()

        XCTAssertNil(result, "Card with wrong service must be dropped")
        let repo = BriefRepository(database: db)
        XCTAssertEqual(try repo.fetchUnattachedMessages().count, 1,
                       "Messages must remain unattached when all cards fail validation")
    }

    // Mix of valid and invalid sourceMessageIds — only valid ones survive.
    func testPartiallyValidSourceIdsRetainValidOnes() async throws {
        let db = try makeDB()
        try await insertMessages(db: db, messageIds: ["m1", "m2"])

        let json = """
        {"cards":[{"id":"signal-c1-1","service":"signal","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":2,"threads":1,"people":1},
        "sourceMessageIds":["m1","hallucinated","m2"]}]}
        """
        let mock = RiggedMock(json)
        let engine = makeBriefEngine(db: db, mock: mock)
        let result = try await engine.processNewMessages()

        XCTAssertNotNil(result)
        let repo = BriefRepository(database: db)
        let cards = try repo.fetchBriefCards(briefID: result!)
        let sources = try repo.fetchSources(briefCardID: cards[0].id)
        XCTAssertEqual(sources.count, 2, "Only the two valid sourceMessageIds should produce sources")
        let sourceMessageIds = sources.map(\.messageId).sorted()
        XCTAssertEqual(sourceMessageIds, ["m1", "m2"])
    }

    // Multiple cards for different conversations in the same service — all valid.
    func testMultipleValidCardsForDifferentConversations() async throws {
        let db = try makeDB()
        let now = Date()
        try await insertMessages(db: db, convId: "c1", messageIds: ["m1"], baseTime: now)
        try await insertMessages(db: db, convId: "c2", messageIds: ["m2"], sender: "Bob",
                                 baseTime: now.addingTimeInterval(5))

        let json = """
        {"cards":[
          {"id":"signal-c1-1","service":"signal","conversationId":"c1",
           "headline":"H1","priority":"medium","summary":"S1",
           "counts":{"messages":1,"threads":1,"people":1},
           "sourceMessageIds":["m1"]},
          {"id":"signal-c2-1","service":"signal","conversationId":"c2",
           "headline":"H2","priority":"low","summary":"S2",
           "counts":{"messages":1,"threads":1,"people":1},
           "sourceMessageIds":["m2"]}
        ]}
        """
        let mock = RiggedMock(json)
        let engine = makeBriefEngine(db: db, mock: mock)
        let result = try await engine.processNewMessages()

        XCTAssertNotNil(result)
        let repo = BriefRepository(database: db)
        let cards = try repo.fetchBriefCards(briefID: result!)
        XCTAssertEqual(cards.count, 2)
        let convIds = Set(cards.map(\.conversationId))
        XCTAssertEqual(convIds, ["c1", "c2"])
    }

    // Duplicate sourceMessageIds in the same card — should not crash or duplicate sources.
    func testDuplicateSourceMessageIdsDoNotCrash() async throws {
        let db = try makeDB()
        try await insertMessages(db: db, messageIds: ["m1"])

        let json = """
        {"cards":[{"id":"signal-c1-1","service":"signal","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":1,"threads":1,"people":1},
        "sourceMessageIds":["m1","m1","m1"]}]}
        """
        let mock = RiggedMock(json)
        let engine = makeBriefEngine(db: db, mock: mock)
        let result = try await engine.processNewMessages()

        XCTAssertNotNil(result, "Duplicate sourceMessageIds must not crash")
    }
}

// MARK: - Context Window Tests

@MainActor
final class ContextWindowTests: XCTestCase {

    // Recent context messages should appear in the LLM prompt before new messages.
    func testRecentContextAppearsBeforeNewMessages() async throws {
        let db = try makeDB()
        let now = Date()
        // Old brief with an attached message (recent context candidate)
        try await db.dbQueue.write { d in
            var brief = Brief(createdAt: now.addingTimeInterval(-3600), status: "ready",
                              services: #"["signal"]"#, openingSummary: nil,
                              notificationText: "old", episodicSummary: nil)
            try brief.insert(d)
            var ctx = Message(briefId: brief.id, service: "signal", conversationId: "c1",
                              messageId: "ctx-1", sender: "Bob", text: "Context message",
                              timestamp: now.addingTimeInterval(-1800), isSent: false)
            try ctx.insert(d)
        }

        // New unattached message
        try await insertMessages(db: db, convId: "c1", messageIds: ["m1"],
                                 baseTime: now.addingTimeInterval(-10))

        let capturingMock = CapturingMockLLMClient()
        capturingMock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        let engine = makeBriefEngine(db: db, mock: capturingMock)
        _ = try await engine.processNewMessages()

        let briefCall = capturingMock.capturedCalls.first { !$0.systemPrompt.contains("2-3 sentences") }
        let userContent = briefCall?.userContent ?? ""
        XCTAssertTrue(userContent.contains("[Recent context before new messages]"),
                      "Prompt must include recent context section")
        XCTAssertTrue(userContent.contains("Context message"),
                      "Recent context message text must appear in prompt")

        let contextPos = userContent.range(of: "Context message")!.lowerBound
        let newMsgPos = userContent.range(of: "Message m1")!.lowerBound
        XCTAssertTrue(contextPos < newMsgPos,
                      "Context messages must appear before new messages in the prompt")
    }

    // When there are no recent context messages, the section should be omitted.
    func testNoRecentContextOmitsSection() async throws {
        let db = try makeDB()
        try await insertMessages(db: db, messageIds: ["m1"])

        let capturingMock = CapturingMockLLMClient()
        capturingMock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        let engine = makeBriefEngine(db: db, mock: capturingMock)
        _ = try await engine.processNewMessages()

        let briefCall = capturingMock.capturedCalls.first { !$0.systemPrompt.contains("2-3 sentences") }
        let userContent = briefCall?.userContent ?? ""
        XCTAssertFalse(userContent.contains("[Recent context before new messages]"),
                       "No recent context section when no prior messages exist")
    }

    // Conversation with >100 messages — should be capped to suffix of 100.
    func testLargeConversationIsCappedAt100Messages() async throws {
        let db = try makeDB()
        let now = Date()
        let ids = (0..<120).map { "m\($0)" }
        try await insertMessages(db: db, messageIds: ids, baseTime: now.addingTimeInterval(-200))

        let capturingMock = CapturingMockLLMClient()
        capturingMock.specs["signal"] = .init(convId: "c1", messageIds: Array(ids.suffix(10)))
        let engine = makeBriefEngine(db: db, mock: capturingMock)
        _ = try await engine.processNewMessages()

        let briefCall = capturingMock.capturedCalls.first { !$0.systemPrompt.contains("2-3 sentences") }
        let userContent = briefCall?.userContent ?? ""
        // 120 - 100 = 20 omitted from the new messages section
        XCTAssertTrue(userContent.contains("20 earlier new messages omitted"),
                      "Must indicate omitted message count when capping at 100")
        // m20 is the first message in the capped suffix
        XCTAssertTrue(userContent.contains("[id=m20 |"), "m20 should be included (first of suffix 100)")
        XCTAssertTrue(userContent.contains("[id=m119 |"), "m119 should be included (last message)")
        // The [New messages] section should exist
        XCTAssertTrue(userContent.contains("[New messages]"))
    }

    // Sender name resolution: UUID >20 chars should show "Unknown".
    func testLongUUIDSenderShowsUnknown() async throws {
        let db = try makeDB()
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m1", sender: uuid, text: "Hi",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }

        let capturingMock = CapturingMockLLMClient()
        capturingMock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        let engine = makeBriefEngine(db: db, mock: capturingMock)
        _ = try await engine.processNewMessages()

        let briefCall = capturingMock.capturedCalls.first { !$0.systemPrompt.contains("2-3 sentences") }
        let userContent = briefCall?.userContent ?? ""
        XCTAssertTrue(userContent.contains("Unknown:"),
                      "UUID sender >20 chars should be resolved to 'Unknown'")
        XCTAssertFalse(userContent.contains(uuid),
                       "Raw UUID should not appear in the prompt")
    }

    // Short sender name (<=20 chars) passes through unchanged.
    func testShortSenderNamePassesThrough() async throws {
        let db = try makeDB()
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m1", sender: "ShortName12345678901", text: "Hi",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }

        let capturingMock = CapturingMockLLMClient()
        capturingMock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        let engine = makeBriefEngine(db: db, mock: capturingMock)
        _ = try await engine.processNewMessages()

        let briefCall = capturingMock.capturedCalls.first { !$0.systemPrompt.contains("2-3 sentences") }
        let userContent = briefCall?.userContent ?? ""
        // Exactly 20 chars — should pass through
        XCTAssertTrue(userContent.contains("ShortName12345678901:"),
                      "Sender name with exactly 20 chars should pass through")
    }
}

// MARK: - Conversation State Carry-Forward

@MainActor
final class ConversationStateCarryForwardTests: XCTestCase {

    // Action items from cycle 1 should appear as unresolved actions in cycle 2's prompt.
    func testActionItemsAppearAsUnresolvedInNextCycle() async throws {
        let db = try makeDB()
        let now = Date()
        let repo = BriefRepository(database: db)

        // Cycle 1: card has actionItems
        let mock1 = DynamicMockLLMClient()
        mock1.specs["signal"] = .init(convId: "c1", messageIds: ["m1"], actions: ["Reply to Bob"])
        try await insertMessages(db: db, messageIds: ["m1"], baseTime: now.addingTimeInterval(-120))
        _ = try await makeBriefEngine(db: db, mock: mock1).processNewMessages()

        let state = try repo.fetchConversationState(service: "signal", conversationID: "c1")
        XCTAssertNotNil(state?.unresolvedActions)
        XCTAssertTrue(state!.unresolvedActions!.contains("Reply to Bob"))

        // Cycle 2: new message — prompt should include unresolved actions
        try await insertMessages(db: db, messageIds: ["m2"], baseTime: now.addingTimeInterval(-10))
        let capturingMock = CapturingMockLLMClient()
        capturingMock.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])
        _ = try await makeBriefEngine(db: db, mock: capturingMock).processNewMessages()

        let briefCall = capturingMock.capturedCalls.first { !$0.systemPrompt.contains("2-3 sentences") }
        let userContent = briefCall?.userContent ?? ""
        XCTAssertTrue(userContent.contains("Unresolved actions from prior brief:"),
                      "Cycle 2 prompt must include unresolved actions header")
        XCTAssertTrue(userContent.contains("Reply to Bob"),
                      "Specific action item must appear in cycle 2 prompt")
    }

    // Empty actionItems clears unresolvedActions in the state.
    func testEmptyActionItemsClearsUnresolvedState() async throws {
        let db = try makeDB()
        let now = Date()
        let repo = BriefRepository(database: db)

        // Cycle 1: with actions
        let mock1 = DynamicMockLLMClient()
        mock1.specs["signal"] = .init(convId: "c1", messageIds: ["m1"], actions: ["Call Alice"])
        try await insertMessages(db: db, messageIds: ["m1"], baseTime: now.addingTimeInterval(-120))
        _ = try await makeBriefEngine(db: db, mock: mock1).processNewMessages()

        // Cycle 2: no actions (resolved)
        let mock2 = DynamicMockLLMClient()
        mock2.specs["signal"] = .init(convId: "c1", messageIds: ["m2"], actions: [])
        try await insertMessages(db: db, messageIds: ["m2"], baseTime: now.addingTimeInterval(-10))
        _ = try await makeBriefEngine(db: db, mock: mock2).processNewMessages()

        let state = try repo.fetchConversationState(service: "signal", conversationID: "c1")
        XCTAssertNil(state?.unresolvedActions,
                     "Empty actionItems should clear unresolvedActions (actions resolved)")
    }

    // Previous brief card headline appears in next cycle's prompt.
    func testPreviousHeadlineAppearsInNextCycle() async throws {
        let db = try makeDB()
        let now = Date()

        // Cycle 1
        let mock1 = DynamicMockLLMClient()
        mock1.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        try await insertMessages(db: db, messageIds: ["m1"], baseTime: now.addingTimeInterval(-120))
        _ = try await makeBriefEngine(db: db, mock: mock1).processNewMessages()

        // Cycle 2: capture prompt
        try await insertMessages(db: db, messageIds: ["m2"], baseTime: now.addingTimeInterval(-10))
        let capturingMock = CapturingMockLLMClient()
        capturingMock.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])
        _ = try await makeBriefEngine(db: db, mock: capturingMock).processNewMessages()

        let briefCall = capturingMock.capturedCalls.first { !$0.systemPrompt.contains("2-3 sentences") }
        let userContent = briefCall?.userContent ?? ""
        XCTAssertTrue(userContent.contains("Previous brief card:"),
                      "Prompt must include previous card headline for context continuity")
    }

    // Same conversationId on different services should not share state.
    func testSameConvIdDifferentServicesHaveSeparateState() async throws {
        let db = try makeDB()
        let now = Date()
        let repo = BriefRepository(database: db)

        try await db.dbQueue.write { d in
            try ServiceConfig.default(for: "signal").insert(d)
            try ServiceConfig.default(for: "telegram").insert(d)
        }

        // Signal message
        try await insertMessages(db: db, service: "signal", convId: "c1",
                                 messageIds: ["sig-m1"], sender: "Alice", baseTime: now)
        // Telegram message with same convId
        try await insertMessages(db: db, service: "telegram", convId: "c1",
                                 messageIds: ["tg-m1"], sender: "Bob",
                                 baseTime: now.addingTimeInterval(1))

        // DynamicMockLLMClient detects service from "Connected services:" line (not plain contains)
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["sig-m1"], actions: ["Signal action"])
        mock.specs["telegram"] = .init(convId: "c1", messageIds: ["tg-m1"], actions: ["Telegram action"])

        let engine = makeBriefEngine(db: db, mock: mock)
        _ = try await engine.processNewMessages()

        let signalState = try repo.fetchConversationState(service: "signal", conversationID: "c1")
        let telegramState = try repo.fetchConversationState(service: "telegram", conversationID: "c1")

        XCTAssertNotNil(signalState, "Signal state must exist for (signal, c1)")
        XCTAssertNotNil(telegramState, "Telegram state must exist for (telegram, c1)")
        // Both states reference the same convId but different services — they're separate rows
        XCTAssertEqual(signalState?.lastSeenMessageId, "sig-m1")
        XCTAssertEqual(telegramState?.lastSeenMessageId, "tg-m1")
        XCTAssertTrue(signalState!.unresolvedActions!.contains("Signal action"))
        XCTAssertTrue(telegramState!.unresolvedActions!.contains("Telegram action"))
    }
}

// MARK: - Compression Error Handling

@MainActor
final class CompressionErrorHandlingTests: XCTestCase {

    // When compression LLM fails, empty sentinel is written and next brief still succeeds.
    func testCompressionFailureWritesSentinelAndNextBriefSucceeds() async throws {
        let db = try makeDB()
        let now = Date()

        // Brief 1 (to be compressed)
        try await db.dbQueue.write { d in
            var b = Brief(createdAt: now.addingTimeInterval(-7200), status: "ready",
                          services: #"["signal"]"#, openingSummary: nil,
                          notificationText: "old", episodicSummary: nil)
            try b.insert(d)
            var m = Message(briefId: b.id, service: "signal", conversationId: "c1",
                            messageId: "m-old", sender: "Alice", text: "Old message",
                            timestamp: now.addingTimeInterval(-7200), isSent: false)
            try m.insert(d)
        }

        // New unattached message
        try await insertMessages(db: db, messageIds: ["m1"], baseTime: now.addingTimeInterval(-10))

        // Mock that fails on compression but succeeds on brief generation
        let mock = CompressionFailMock()
        mock.briefSpec = .init(convId: "c1", messageIds: ["m1"])
        let engine = makeBriefEngine(db: db, mock: mock)
        let result = try await engine.processNewMessages()

        // Brief should still be created
        XCTAssertNotNil(result, "Brief must succeed even when compression fails")

        // Old brief should have empty sentinel
        let oldBrief = try await db.dbQueue.read { d in
            try Brief.order(Column("createdAt").asc).fetchAll(d).first
        }
        XCTAssertEqual(oldBrief?.episodicSummary, "",
                       "Failed compression must write empty sentinel so it's not retried")
    }

    // A brief with empty sentinel is never re-compressed.
    func testEmptySentinelBriefIsNotReCompressed() async throws {
        let db = try makeDB()
        let now = Date()

        // Insert brief with empty sentinel
        try await db.dbQueue.write { d in
            var b = Brief(createdAt: now.addingTimeInterval(-3600), status: "ready",
                          services: #"["signal"]"#, openingSummary: nil,
                          notificationText: "old", episodicSummary: "")
            try b.insert(d)
            var m = Message(briefId: b.id, service: "signal", conversationId: "c1",
                            messageId: "m-old", sender: "Alice", text: "Old",
                            timestamp: now.addingTimeInterval(-3600), isSent: false)
            try m.insert(d)
        }

        // New message for cycle 2
        try await insertMessages(db: db, messageIds: ["m1"], baseTime: now.addingTimeInterval(-10))

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        let engine = makeBriefEngine(db: db, mock: mock)
        _ = try await engine.processNewMessages()

        // Compressor should NOT have been called (no "2-3 sentences" call)
        // The DynamicMock would have callCount=1 for the brief, +0 for compression
        XCTAssertEqual(mock.callCount, 1,
                       "Compression must not be attempted on briefs with empty sentinel")
    }

    // Compression runs oldest-first — if B1 and B2 both lack episodicSummary,
    // only B1 gets compressed on cycle 3.
    func testCompressionRunsOldestFirst() async throws {
        let db = try makeDB()
        let now = Date()

        // B1 (oldest, no episodicSummary)
        try await db.dbQueue.write { d in
            var b1 = Brief(createdAt: now.addingTimeInterval(-7200), status: "ready",
                           services: #"["signal"]"#, openingSummary: nil,
                           notificationText: "b1", episodicSummary: nil)
            try b1.insert(d)
            var m1 = Message(briefId: b1.id, service: "signal", conversationId: "c1",
                             messageId: "m-b1", sender: "Alice", text: "B1 msg",
                             timestamp: now.addingTimeInterval(-7200), isSent: false)
            try m1.insert(d)
        }

        // B2 (newer, no episodicSummary)
        try await db.dbQueue.write { d in
            var b2 = Brief(createdAt: now.addingTimeInterval(-3600), status: "ready",
                           services: #"["signal"]"#, openingSummary: nil,
                           notificationText: "b2", episodicSummary: nil)
            try b2.insert(d)
            var m2 = Message(briefId: b2.id, service: "signal", conversationId: "c1",
                             messageId: "m-b2", sender: "Alice", text: "B2 msg",
                             timestamp: now.addingTimeInterval(-3600), isSent: false)
            try m2.insert(d)
        }

        // New message for cycle 3
        try await insertMessages(db: db, messageIds: ["m3"], baseTime: now.addingTimeInterval(-10))

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m3"])
        _ = try await makeBriefEngine(db: db, mock: mock).processNewMessages()

        let briefs = try await db.dbQueue.read { d in
            try Brief.order(Column("createdAt").asc).fetchAll(d)
        }
        XCTAssertEqual(briefs.count, 3)
        XCTAssertNotNil(briefs[0].episodicSummary, "B1 (oldest) must be compressed first")
        XCTAssertNil(briefs[1].episodicSummary, "B2 must still be uncompressed — only one per cycle")
    }
}

// MARK: - Repository Query Boundary Tests

@MainActor
final class RepositoryBoundaryTests: XCTestCase {

    // fetchRecentContextMessages with exact boundary: `before` excludes the exact timestamp.
    func testRecentContextExcludesExactBeforeTimestamp() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let t = Date()

        // Create a brief so messages can reference a valid briefId
        let briefId = try await db.dbQueue.write { d -> Int64 in
            var b = Brief(createdAt: t, status: "ready", services: #"["signal"]"#,
                          openingSummary: nil, notificationText: "x", episodicSummary: nil)
            try b.insert(d)
            return b.id!
        }

        try await db.dbQueue.write { d in
            for (i, msgId) in ["m1", "m2", "m3"].enumerated() {
                var m = Message(briefId: briefId, service: "signal", conversationId: "c1",
                                messageId: msgId, sender: "Alice", text: "msg",
                                timestamp: t.addingTimeInterval(Double(i) * 10), isSent: false)
                try m.insert(d)
            }
        }

        // before = m2's exact timestamp — m2 should be excluded
        let result = try repo.fetchRecentContextMessages(
            service: "signal", conversationID: "c1",
            before: t.addingTimeInterval(10), limit: 10
        )
        XCTAssertEqual(result.count, 1, "Only m1 should be returned (m2 excluded by strict <)")
        XCTAssertEqual(result[0].messageId, "m1")
    }

    // fetchRecentContextMessages with since boundary: `since` includes the exact timestamp.
    func testRecentContextIncludesExactSinceTimestamp() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let t = Date()

        let briefId = try await db.dbQueue.write { d -> Int64 in
            var b = Brief(createdAt: t, status: "ready", services: #"["signal"]"#,
                          openingSummary: nil, notificationText: "x", episodicSummary: nil)
            try b.insert(d)
            return b.id!
        }

        try await db.dbQueue.write { d in
            for (i, msgId) in ["m1", "m2", "m3"].enumerated() {
                var m = Message(briefId: briefId, service: "signal", conversationId: "c1",
                                messageId: msgId, sender: "Alice", text: "msg",
                                timestamp: t.addingTimeInterval(Double(i) * 10), isSent: false)
                try m.insert(d)
            }
        }

        // since = m2's exact timestamp, before = m3's timestamp + 1
        let result = try repo.fetchRecentContextMessages(
            service: "signal", conversationID: "c1",
            before: t.addingTimeInterval(25),
            since: t.addingTimeInterval(10), limit: 10
        )
        XCTAssertEqual(result.count, 2, "m2 and m3 should be included (since uses >=)")
    }

    // fetchRecentContextMessages respects the limit parameter.
    func testRecentContextRespectsLimit() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let t = Date()

        let briefId = try await db.dbQueue.write { d -> Int64 in
            var b = Brief(createdAt: t, status: "ready", services: #"["signal"]"#,
                          openingSummary: nil, notificationText: "x", episodicSummary: nil)
            try b.insert(d)
            return b.id!
        }

        try await db.dbQueue.write { d in
            for i in 0..<10 {
                var m = Message(briefId: briefId, service: "signal", conversationId: "c1",
                                messageId: "m\(i)", sender: "Alice", text: "msg",
                                timestamp: t.addingTimeInterval(Double(i)), isSent: false)
                try m.insert(d)
            }
        }

        let result = try repo.fetchRecentContextMessages(
            service: "signal", conversationID: "c1",
            before: t.addingTimeInterval(100), limit: 3
        )
        XCTAssertEqual(result.count, 3)
        // Should return the LAST 3 (most recent), ordered chronologically
        XCTAssertEqual(result.map(\.messageId), ["m7", "m8", "m9"])
    }

    // fetchRecentContextMessages with no matching messages returns empty.
    func testRecentContextEmptyWhenNoMatches() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)

        let result = try repo.fetchRecentContextMessages(
            service: "signal", conversationID: "c1",
            before: Date(), limit: 10
        )
        XCTAssertTrue(result.isEmpty)
    }

    // fetchUnattachedMessages excludes sent messages.
    func testUnattachedMessagesExcludesSentMessages() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)

        try await db.dbQueue.write { d in
            var received = Message(briefId: nil, service: "signal", conversationId: "c1",
                                   messageId: "m1", sender: "Alice", text: "Hi",
                                   timestamp: Date(), isSent: false)
            try received.insert(d)
            var sent = Message(briefId: nil, service: "signal", conversationId: "c1",
                               messageId: "m2", sender: "me", text: "Reply",
                               timestamp: Date(), isSent: true)
            try sent.insert(d)
        }

        let unattached = try repo.fetchUnattachedMessages()
        XCTAssertEqual(unattached.count, 1, "Only received messages should be unattached")
        XCTAssertEqual(unattached[0].messageId, "m1")
    }

    // fetchUnattachedMessages excludes messages older than 7 days.
    func testUnattachedMessagesExcludesOldMessages() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)

        try await db.dbQueue.write { d in
            var recent = Message(briefId: nil, service: "signal", conversationId: "c1",
                                 messageId: "m-recent", sender: "Alice", text: "Fresh",
                                 timestamp: Date(), isSent: false)
            try recent.insert(d)
            var old = Message(briefId: nil, service: "signal", conversationId: "c1",
                              messageId: "m-old", sender: "Alice", text: "Stale",
                              timestamp: Date().addingTimeInterval(-8 * 24 * 3600), isSent: false)
            try old.insert(d)
        }

        let unattached = try repo.fetchUnattachedMessages()
        XCTAssertEqual(unattached.count, 1)
        XCTAssertEqual(unattached[0].messageId, "m-recent")
    }

    // recentEpisodicSummaries filters by service via LIKE pattern.
    func testEpisodicSummariesFilterByService() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let now = Date()

        try await db.dbQueue.write { d in
            var b1 = Brief(createdAt: now.addingTimeInterval(-120), status: "ready",
                           services: #"["signal"]"#, openingSummary: nil,
                           notificationText: "b1", episodicSummary: "Signal context")
            try b1.insert(d)
            var b2 = Brief(createdAt: now.addingTimeInterval(-60), status: "ready",
                           services: #"["telegram"]"#, openingSummary: nil,
                           notificationText: "b2", episodicSummary: "Telegram context")
            try b2.insert(d)
        }

        let signalSummaries = try repo.recentEpisodicSummaries(service: "signal", limit: 10)
        XCTAssertEqual(signalSummaries.count, 1)
        XCTAssertEqual(signalSummaries[0].summary, "Signal context")

        let telegramSummaries = try repo.recentEpisodicSummaries(service: "telegram", limit: 10)
        XCTAssertEqual(telegramSummaries.count, 1)
        XCTAssertEqual(telegramSummaries[0].summary, "Telegram context")
    }

    // recentEpisodicSummaries excludes empty sentinel.
    func testEpisodicSummariesExcludesEmptySentinel() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)

        try await db.dbQueue.write { d in
            var b1 = Brief(createdAt: Date().addingTimeInterval(-120), status: "ready",
                           services: #"["signal"]"#, openingSummary: nil,
                           notificationText: "b1", episodicSummary: "")
            try b1.insert(d)
            var b2 = Brief(createdAt: Date().addingTimeInterval(-60), status: "ready",
                           services: #"["signal"]"#, openingSummary: nil,
                           notificationText: "b2", episodicSummary: "Real summary")
            try b2.insert(d)
        }

        let summaries = try repo.recentEpisodicSummaries(service: "signal", limit: 10)
        XCTAssertEqual(summaries.count, 1, "Empty sentinel must be excluded")
        XCTAssertEqual(summaries[0].summary, "Real summary")
    }
}

// MARK: - Multi-Service Partial Failure

@MainActor
final class MultiServicePartialFailureTests: XCTestCase {

    // One service's LLM call fails, the other succeeds — brief contains only successful service.
    func testPartialLLMFailureKeepsSuccessfulService() async throws {
        let db = try makeDB()
        let now = Date()

        try await db.dbQueue.write { d in
            try ServiceConfig.default(for: "signal").insert(d)
            try ServiceConfig.default(for: "telegram").insert(d)
        }
        try await insertMessages(db: db, service: "signal", messageIds: ["sig-m1"], baseTime: now)
        try await insertMessages(db: db, service: "telegram", messageIds: ["tg-m1"],
                                 baseTime: now.addingTimeInterval(1))

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["sig-m1"])
        mock.specs["telegram"] = .init(convId: "c1", messageIds: ["tg-m1"], fail: true)
        let engine = makeBriefEngine(db: db, mock: mock)
        let result = try await engine.processNewMessages()

        XCTAssertNotNil(result, "Brief must be created for the successful service")
        let repo = BriefRepository(database: db)
        let brief = try repo.fetchBrief(id: result!)!
        let services = try JSONDecoder().decode([String].self, from: Data(brief.services.utf8))
        XCTAssertTrue(services.contains("signal"))
        XCTAssertFalse(services.contains("telegram"))

        // failedServices should include telegram
        XCTAssertNotNil(brief.failedServices)
        let failed = try JSONDecoder().decode([String].self, from: Data(brief.failedServices!.utf8))
        XCTAssertTrue(failed.contains("telegram"))

        // Signal messages attached, telegram messages remain unattached
        let sigMsg = try await db.dbQueue.read { d in
            try Message.filter(Column("messageId") == "sig-m1").fetchOne(d)
        }
        let tgMsg = try await db.dbQueue.read { d in
            try Message.filter(Column("messageId") == "tg-m1").fetchOne(d)
        }
        XCTAssertNotNil(sigMsg?.briefId, "Signal message must be attached")
        XCTAssertNil(tgMsg?.briefId, "Telegram message must remain unattached for retry")
    }

    // Both services fail — no brief created, all messages stay unattached.
    func testAllServicesFailProducesNoBrief() async throws {
        let db = try makeDB()
        let now = Date()

        try await db.dbQueue.write { d in
            try ServiceConfig.default(for: "signal").insert(d)
            try ServiceConfig.default(for: "telegram").insert(d)
        }
        try await insertMessages(db: db, service: "signal", messageIds: ["sig-m1"], baseTime: now)
        try await insertMessages(db: db, service: "telegram", messageIds: ["tg-m1"],
                                 baseTime: now.addingTimeInterval(1))

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["sig-m1"], fail: true)
        mock.specs["telegram"] = .init(convId: "c1", messageIds: ["tg-m1"], fail: true)
        let engine = makeBriefEngine(db: db, mock: mock)
        let result = try await engine.processNewMessages()

        XCTAssertNil(result, "No brief when all services fail")
        let repo = BriefRepository(database: db)
        let unattached = try repo.fetchUnattachedMessages()
        XCTAssertEqual(unattached.count, 2, "All messages must remain unattached for retry")
    }
}

// MARK: - Private Mocks

private final class RiggedMock: LLMClient {
    let payload: String
    init(_ payload: String) { self.payload = payload }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        let sys = messages.first(where: { $0.role == .system })?.content ?? ""
        if sys.contains("2-3 sentences") {
            return LLMResponse(text: "Compression summary.", inputTokens: 5, outputTokens: 5)
        }
        return LLMResponse(text: payload, inputTokens: 10, outputTokens: 20)
    }
}

private final class CompressionFailMock: LLMClient {
    var briefSpec: DynamicMockLLMClient.Spec?

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        let sys = messages.first(where: { $0.role == .system })?.content ?? ""
        if sys.contains("2-3 sentences") {
            throw URLError(.timedOut)
        }
        guard let spec = briefSpec else {
            throw NSError(domain: "Test", code: 0, userInfo: nil)
        }
        let connectedLine = sys.split(separator: "\n")
            .first { $0.hasPrefix("Connected services:") }
            .map(String.init) ?? ""
        let service = ["signal", "telegram", "imessage"].first { connectedLine.contains($0) } ?? "signal"
        let ids = spec.messageIds.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {"cards":[{"id":"\(service)-\(spec.convId)-1","service":"\(service)",
        "conversationId":"\(spec.convId)","headline":"H","priority":"medium",
        "summary":"S","counts":{"messages":\(spec.messageIds.count),"threads":1,"people":1},
        "sourceMessageIds":[\(ids)]}]}
        """
        return LLMResponse(text: json, inputTokens: 10, outputTokens: 20)
    }
}
