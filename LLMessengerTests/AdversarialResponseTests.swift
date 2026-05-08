// LLMessengerTests/AdversarialResponseTests.swift
// Tests that BriefEngine is resilient against pathological LLM output.
// The LLM is the one component the system fundamentally cannot control. These tests verify
// that every failure mode is isolated, detected, and leaves the system in a safe state
// (messages unattached and retryable, no corrupt or partial briefs stored).
import XCTest
import GRDB
@testable import LLMessenger

// MARK: - RiggedMockLLMClient
//
// Returns a fixed payload for every briefing call, regardless of input.
// Compressor calls (detected by "2-3 sentences" in system prompt) get a safe fallback.

private final class RiggedMockLLMClient: LLMClient {
    let payload: String
    init(_ payload: String) { self.payload = payload }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        let sys = messages.first(where: { $0.role == .system })?.content ?? ""
        if sys.contains("2-3 sentences") {
            return LLMResponse(text: "Compressor summary.", inputTokens: 5, outputTokens: 5)
        }
        return LLMResponse(text: payload, inputTokens: 10, outputTokens: 20)
    }
}

// MARK: - ThrowingMockLLMClient

private final class ThrowingMockLLMClient: LLMClient {
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - AdversarialResponseTests

@MainActor
final class AdversarialResponseTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func insertSignalMessage(db: AppDatabase,
                                     messageId: String = "m1",
                                     convId: String = "c1") async throws {
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: convId,
                            conversationName: "Alice", messageId: messageId, sender: "Alice",
                            text: "Hello", timestamp: Date(), isSent: false)
            try m.insert(d)
        }
    }

    private func unattachedCount(db: AppDatabase) throws -> Int {
        try BriefRepository(database: db).fetchUnattachedMessages().count
    }

    // MARK: - Malformed / non-JSON responses

    func testPlainTextResponseProducesNoBriefAndMessagesRemainRetryable() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db)

        let engine = BriefEngine(database: db, client: RiggedMockLLMClient("I'm sorry, I can't do that."),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNil(result, "Non-JSON response must not produce a brief")
        XCTAssertEqual(try unattachedCount(db: db), 1,
                       "Messages must remain unattached after non-JSON response — they must be retryable")
    }

    func testEmptyStringResponseProducesNoBrief() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db)

        let engine = BriefEngine(database: db, client: RiggedMockLLMClient(""),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNil(result)
        XCTAssertEqual(try unattachedCount(db: db), 1)
    }

    func testPartiallyValidJSONProducesNoBrief() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db)

        let engine = BriefEngine(database: db, client: RiggedMockLLMClient(#"{"cards": [{"id": "oops""#),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNil(result)
        XCTAssertEqual(try unattachedCount(db: db), 1)
    }

    // MARK: - Markdown-wrapped JSON (LLM ignores "Output ONLY valid JSON" instruction)

    func testMarkdownFenceWrappedJSONIsStrippedAndAccepted() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db)

        let wrappedJSON = """
        ```json
        {
          "cards": [{
            "id": "signal-c1-1",
            "service": "signal",
            "conversationId": "c1",
            "headline": "Update",
            "priority": "medium",
            "summary": "Alice said hello.",
            "counts": {"messages": 1, "threads": 1, "people": 1},
            "sourceMessageIds": ["m1"]
          }]
        }
        ```
        """

        let engine = BriefEngine(database: db, client: RiggedMockLLMClient(wrappedJSON),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNotNil(result, "Markdown-wrapped JSON must be stripped and parsed — LLMs routinely ignore format instructions")
    }

    // MARK: - Schema violations caught by BriefEngine.decodeAndValidateBrief

    func testEmptyCardsArrayProducesNoBrief() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db)

        let engine = BriefEngine(database: db, client: RiggedMockLLMClient(#"{"cards":[]}"#),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNil(result, "Empty cards array must be rejected — brief would be useless")
        XCTAssertEqual(try unattachedCount(db: db), 1)
    }

    func testWrongServiceInCardRejectsEntireServiceBatch() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db)

        // LLM returns a card claiming to be "telegram" but we're processing "signal"
        let wrongServiceJSON = """
        {"cards":[{"id":"t-c1-1","service":"telegram","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":1,"threads":1,"people":1},
        "sourceMessageIds":["m1"]}]}
        """
        let engine = BriefEngine(database: db, client: RiggedMockLLMClient(wrongServiceJSON),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNil(result, "Card with wrong service tag must be rejected")
        XCTAssertEqual(try unattachedCount(db: db), 1,
                       "Messages must survive wrong-service rejection")
    }

    func testMissingSourceMessageIdsRejectsCard() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db)

        let noSourcesJSON = """
        {"cards":[{"id":"signal-c1-1","service":"signal","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":1,"threads":1,"people":1},
        "sourceMessageIds":[]}]}
        """
        let engine = BriefEngine(database: db, client: RiggedMockLLMClient(noSourcesJSON),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNil(result, "Card with empty sourceMessageIds must be rejected — it would be an unverifiable brief")
        XCTAssertEqual(try unattachedCount(db: db), 1)
    }

    func testUnknownSourceMessageIdRejectsCard() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db, messageId: "real-m1")

        // LLM hallucinates a messageId that doesn't exist in the DB
        let hallucinatedJSON = """
        {"cards":[{"id":"signal-c1-1","service":"signal","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":1,"threads":1,"people":1},
        "sourceMessageIds":["hallucinated-id-that-never-existed"]}]}
        """
        let engine = BriefEngine(database: db, client: RiggedMockLLMClient(hallucinatedJSON),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNil(result,
                     "Hallucinated sourceMessageId must be rejected — cards must only reference real messages")
        XCTAssertEqual(try unattachedCount(db: db), 1)
    }

    func testEmptyStringSourceMessageIdIsFilteredAndRemainingIdValidates() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db, messageId: "m1")

        // Empty string gets filtered by `filter { !$0.isEmpty }` — remaining "m1" is valid
        let mixedSourcesJSON = """
        {"cards":[{"id":"signal-c1-1","service":"signal","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":1,"threads":1,"people":1},
        "sourceMessageIds":["","m1"]}]}
        """
        let engine = BriefEngine(database: db, client: RiggedMockLLMClient(mixedSourcesJSON),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNotNil(result,
                        "Empty string in sourceMessageIds is filtered out — remaining valid ID must succeed")
    }

    // MARK: - All-or-nothing per service: one bad card kills the whole service batch

    func testOneInvalidCardAmongValidOnesRejectsEntireService() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db, messageId: "m1", convId: "c1")
        // Second message in same service
        try await db.dbQueue.write { d in
            var m2 = Message(briefId: nil, service: "signal", conversationId: "c2",
                             conversationName: "Bob", messageId: "m2", sender: "Bob",
                             text: "Hi", timestamp: Date().addingTimeInterval(1), isSent: false)
            try m2.insert(d)
        }

        // Two cards: first is valid, second has hallucinated sourceMessageId
        let mixedJSON = """
        {"cards":[
          {"id":"signal-c1-1","service":"signal","conversationId":"c1",
           "headline":"H","priority":"medium","summary":"S",
           "counts":{"messages":1,"threads":1,"people":1},
           "sourceMessageIds":["m1"]},
          {"id":"signal-c2-1","service":"signal","conversationId":"c2",
           "headline":"H2","priority":"medium","summary":"S2",
           "counts":{"messages":1,"threads":1,"people":1},
           "sourceMessageIds":["does-not-exist"]}
        ]}
        """
        let engine = BriefEngine(database: db, client: RiggedMockLLMClient(mixedJSON),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        // BriefEngine validates all cards atomically — one bad card rejects all
        XCTAssertNil(result,
                     "One invalid card among valid ones must reject the entire service batch (all-or-nothing)")
        XCTAssertEqual(try unattachedCount(db: db), 2,
                       "Both messages must remain unattached after all-or-nothing rejection")
    }

    // MARK: - Extra fields (forward compatibility)

    func testJSONWithExtraUnknownFieldsIsAccepted() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db)

        // A future LLM version might add new fields — they must not break parsing
        let futureJSON = """
        {"cards":[{"id":"signal-c1-1","service":"signal","conversationId":"c1",
        "headline":"H","priority":"medium","summary":"S",
        "counts":{"messages":1,"threads":1,"people":1},
        "sourceMessageIds":["m1"],
        "futureField":"value","anotherNewField":42,"nestedNew":{"key":"val"}}],
        "totalMessages":1,"someNewTopLevelField":true}
        """
        let engine = BriefEngine(database: db, client: RiggedMockLLMClient(futureJSON),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNotNil(result, "Extra unknown JSON fields must be ignored for forward compatibility")
    }

    // MARK: - Network / LLM call failure

    func testLLMCallFailureDoesNotStoreBriefAndMessagesRemainRetryable() async throws {
        let db = try makeDB()
        try await insertSignalMessage(db: db)

        let engine = BriefEngine(database: db, client: ThrowingMockLLMClient(),
                                  model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNil(result, "LLM network failure must not produce a brief")
        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 0, "No brief must be stored after LLM failure")
        XCTAssertEqual(try unattachedCount(db: db), 1,
                       "Messages must survive LLM failure — critical for retry on next poll cycle")
    }
}
