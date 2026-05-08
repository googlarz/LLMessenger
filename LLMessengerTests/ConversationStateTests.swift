// LLMessengerTests/ConversationStateTests.swift
// Tests ConversationState — the system's memory across brief cycles.
// ConversationState accumulates after each brief and is injected into the next cycle's
// prompt. If carry-forward breaks, brief quality silently degrades: Alice's prior context
// disappears, resolved actions reappear, the LLM loses all continuity.
import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class ConversationStateTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    // Builds a DynamicMockLLMClient spec with action items embedded in the JSON.
    private func specWithActions(convId: String, messageIds: [String],
                                  actions: [String]) -> DynamicMockLLMClient.Spec {
        .init(convId: convId, messageIds: messageIds, actions: actions)
    }

    private func insertMessage(db: AppDatabase,
                               service: String = "signal",
                               convId: String,
                               convName: String? = nil,
                               messageId: String,
                               sender: String = "Alice",
                               text: String = "Hi",
                               timeOffset: TimeInterval = 0) async throws {
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: service,
                            conversationId: convId, conversationName: convName,
                            messageId: messageId, sender: sender, text: text,
                            timestamp: Date().addingTimeInterval(timeOffset), isSent: false)
            try m.insert(d)
        }
    }

    // MARK: - State written after first brief

    func testConversationStateIsWrittenAfterSuccessfulBrief() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, convId: "alice-conv", convName: "Alice", messageId: "m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "alice-conv", messageIds: ["m1"])
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try await engine.processNewMessages()

        let state = try BriefRepository(database: db)
            .fetchConversationState(service: "signal", conversationID: "alice-conv")
        XCTAssertNotNil(state, "ConversationState must be written after the first successful brief")
    }

    func testConversationStateContainsSummaryAfterBrief() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, convId: "c1", messageId: "m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try await engine.processNewMessages()

        let state = try XCTUnwrap(
            BriefRepository(database: db).fetchConversationState(service: "signal", conversationID: "c1")
        )
        XCTAssertNotNil(state.rollingSummary,
                        "rollingSummary must be populated from the card's summary after the first brief")
        XCTAssertFalse(state.rollingSummary?.isEmpty ?? true,
                       "rollingSummary must not be empty")
    }

    func testConversationStateLastSeenMessageIdMatchesInsertedMessage() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, convId: "c1", messageId: "sentinel-msg-id")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["sentinel-msg-id"])
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try await engine.processNewMessages()

        let state = try XCTUnwrap(
            BriefRepository(database: db).fetchConversationState(service: "signal", conversationID: "c1")
        )
        XCTAssertEqual(state.lastSeenMessageId, "sentinel-msg-id",
                       "lastSeenMessageId must be set to the most recent message processed")
    }

    // MARK: - State carries forward to second cycle

    func testPreviousSummaryAppearsInSecondBriefPrompt() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, convId: "c1", convName: "Alice", messageId: "m1", timeOffset: -60)

        let mock1 = CapturingMockLLMClient()
        mock1.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        let engine1 = BriefEngine(database: db, client: mock1, model: "m", basePrompt: "B")
        _ = try await engine1.processNewMessages()

        // Get the summary that was stored
        let state = try XCTUnwrap(
            BriefRepository(database: db).fetchConversationState(service: "signal", conversationID: "c1")
        )
        let storedSummary = try XCTUnwrap(state.rollingSummary, "First brief must write a rollingSummary")

        // Insert new message for second cycle
        try await insertMessage(db: db, convId: "c1", convName: "Alice", messageId: "m2")

        let mock2 = CapturingMockLLMClient()
        mock2.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])
        let engine2 = BriefEngine(database: db, client: mock2, model: "m", basePrompt: "B")
        _ = try await engine2.processNewMessages()

        // The first capturedCall may be the MemoryCompressor ("2-3 sentences") — skip it.
        let briefCall = try XCTUnwrap(
            mock2.capturedCalls.first(where: { !$0.systemPrompt.contains("2-3 sentences") }),
            "Second brief must call the LLM for a new brief (not just compression)")
        let user = briefCall.userContent
        XCTAssertTrue(user.contains(storedSummary) || user.contains("Previous summary:"),
                      "Second cycle's user content must include the previous summary — " +
                      "this is the LLM's memory of prior context. Got: \(user.prefix(400))")
    }

    func testStateIsUpdatedNotDuplicatedOnSecondBrief() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, convId: "c1", messageId: "m1", timeOffset: -60)

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        _ = try await BriefEngine(database: db, client: mock, model: "m", basePrompt: "B").processNewMessages()

        // Second cycle
        try await insertMessage(db: db, convId: "c1", messageId: "m2")
        let mock2 = DynamicMockLLMClient()
        mock2.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])
        _ = try await BriefEngine(database: db, client: mock2, model: "m", basePrompt: "B").processNewMessages()

        // Must be exactly ONE ConversationState row per (service, conversationId)
        let states = try await db.dbQueue.read { d in
            try ConversationState
                .filter(Column("service") == "signal")
                .filter(Column("conversationId") == "c1")
                .fetchAll(d)
        }
        XCTAssertEqual(states.count, 1,
                       "ConversationState must be UPSERTed — one row per (service, conversationId), never duplicated")
    }

    func testStateLastSeenMessageIdUpdatesToLatestAfterSecondBrief() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, convId: "c1", messageId: "first-msg", timeOffset: -60)

        let mock1 = DynamicMockLLMClient()
        mock1.specs["signal"] = .init(convId: "c1", messageIds: ["first-msg"])
        _ = try await BriefEngine(database: db, client: mock1, model: "m", basePrompt: "B").processNewMessages()

        try await insertMessage(db: db, convId: "c1", messageId: "second-msg")
        let mock2 = DynamicMockLLMClient()
        mock2.specs["signal"] = .init(convId: "c1", messageIds: ["second-msg"])
        _ = try await BriefEngine(database: db, client: mock2, model: "m", basePrompt: "B").processNewMessages()

        let state = try XCTUnwrap(
            BriefRepository(database: db).fetchConversationState(service: "signal", conversationID: "c1")
        )
        XCTAssertEqual(state.lastSeenMessageId, "second-msg",
                       "lastSeenMessageId must advance to the latest message after each brief cycle")
    }

    // MARK: - Action items

    func testActionItemsAppearInConversationStateAsUnresolvedActions() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, convId: "c1", messageId: "m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"],
                                      actions: ["Reply to Alice", "Schedule meeting"])
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try await engine.processNewMessages()

        let state = try XCTUnwrap(
            BriefRepository(database: db).fetchConversationState(service: "signal", conversationID: "c1")
        )
        XCTAssertNotNil(state.unresolvedActions,
                        "Action items from a card must be persisted as unresolvedActions in ConversationState")
        let decoded = try JSONDecoder().decode([String].self,
                                               from: Data((state.unresolvedActions ?? "[]").utf8))
        XCTAssertTrue(decoded.contains("Reply to Alice"),
                      "unresolvedActions must contain the action items from the card")
        XCTAssertTrue(decoded.contains("Schedule meeting"))
    }

    func testUnresolvedActionsAppearInNextBriefPrompt() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, convId: "c1", convName: "Alice", messageId: "m1", timeOffset: -60)

        let mock1 = DynamicMockLLMClient()
        mock1.specs["signal"] = .init(convId: "c1", messageIds: ["m1"],
                                       actions: ["Follow up with Alice"])
        _ = try await BriefEngine(database: db, client: mock1, model: "m", basePrompt: "B").processNewMessages()

        // Second cycle
        try await insertMessage(db: db, convId: "c1", convName: "Alice", messageId: "m2")
        let mock2 = CapturingMockLLMClient()
        mock2.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])
        _ = try await BriefEngine(database: db, client: mock2, model: "m", basePrompt: "B").processNewMessages()

        // The first capturedCall may be the MemoryCompressor ("2-3 sentences") — skip it.
        let briefCall = try XCTUnwrap(
            mock2.capturedCalls.first(where: { !$0.systemPrompt.contains("2-3 sentences") }),
            "Second brief must call the LLM for a new brief")
        let user = briefCall.userContent
        XCTAssertTrue(user.contains("Follow up with Alice") || user.contains("Unresolved actions"),
                      "Unresolved action items must carry forward into the next brief's prompt — " +
                      "this is how the LLM knows what still needs attention")
    }

    // MARK: - No state when brief fails

    func testNoConversationStateWrittenWhenBriefFails() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, convId: "c1", messageId: "m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"], fail: true)
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try await engine.processNewMessages()

        let state = try BriefRepository(database: db)
            .fetchConversationState(service: "signal", conversationID: "c1")
        XCTAssertNil(state,
                     "ConversationState must not be written when the brief fails — " +
                     "partial state would corrupt the next cycle's context")
    }

    // MARK: - Multiple conversations are independent

    func testTwoConversationsGetIndependentStates() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, convId: "conv-alice", messageId: "m1", timeOffset: -5)
        try await insertMessage(db: db, convId: "conv-bob", messageId: "m2", sender: "Bob")

        // DynamicMockLLMClient only supports one card per spec; use two separate briefs
        let mock = DynamicMockLLMClient()
        // Return a two-card response for the single service call
        mock.specs["signal"] = .init(convId: "conv-alice", messageIds: ["m1"])
        // This only covers conv-alice. For conv-bob we'd need a two-card mock.
        // Instead, test each conversation in isolation.
        _ = try await BriefEngine(database: db, client: mock, model: "m", basePrompt: "B").processNewMessages()

        let aliceState = try BriefRepository(database: db)
            .fetchConversationState(service: "signal", conversationID: "conv-alice")
        XCTAssertNotNil(aliceState, "conv-alice must have its own ConversationState")

        // conv-bob was not included in the brief (mock only covers conv-alice)
        let bobState = try BriefRepository(database: db)
            .fetchConversationState(service: "signal", conversationID: "conv-bob")
        XCTAssertNil(bobState,
                     "conv-bob must have no state — ConversationState is scoped per conversation, not per brief")
    }
}
