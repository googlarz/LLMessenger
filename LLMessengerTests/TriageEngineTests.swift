// LLMessengerTests/TriageEngineTests.swift
import XCTest
import GRDB
@testable import LLMessenger

// MARK: - Mock LLM Client

final class TriageMockLLMClient: LLMClient {
    var stubbedResponse: String = """
    {"priority":"high","needsReply":true,"reason":"Urgent request"}
    """
    var callCount = 0
    var shouldFail = false

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        callCount += 1
        if shouldFail { throw LLMError.networkFailed("mock failure") }
        return LLMResponse(text: stubbedResponse, inputTokens: 10, outputTokens: 10)
    }
}

// MARK: - Helpers

private func makeDB() throws -> AppDatabase {
    try AppDatabase(inMemory: true)
}

private func makeRule(
    contactPattern: String? = nil,
    keywordPattern: String? = nil,
    suppress: Bool = false,
    alwaysNotify: Bool = false
) -> PriorityRule {
    PriorityRule(
        id: nil,
        contactPattern: contactPattern,
        keywordPattern: keywordPattern,
        service: nil,
        setPriority: nil,
        suppress: suppress,
        alwaysNotify: alwaysNotify,
        sortOrder: 0,
        createdAt: Date(),
        quietStart: nil,
        quietEnd: nil
    )
}

private func makeMessages(count: Int = 1) -> [Message] {
    (0..<count).map { i in
        Message(
            id: nil,
            briefId: nil,
            service: "imessage",
            conversationId: "conv1",
            conversationName: "Alice",
            messageId: "msg\(i)",
            sender: "Alice",
            text: "Hello \(i)",
            timestamp: Date().addingTimeInterval(Double(i)),
            isSent: false
        )
    }
}

// MARK: - Tests

final class TriageEngineTests: XCTestCase {

    // Test 1: alwaysNotify rule fires without calling LLM
    func testAlwaysNotifyRuleShortCircuits() async throws {
        let db = try makeDB()
        let mockLLM = TriageMockLLMClient()
        let nm = await NotificationManager()
        let engine = TriageEngine(db: db, llmClient: mockLLM, notificationManager: nm)
        let rule = makeRule(contactPattern: "Alice", alwaysNotify: true)
        let messages = makeMessages()

        try await engine.triage(
            service: "imessage",
            conversationId: "conv1",
            conversationName: "Alice",
            messages: messages,
            rules: [rule]
        )

        XCTAssertEqual(mockLLM.callCount, 0, "LLM should not be called when alwaysNotify rule matches")

        let events = try await db.dbQueue.read { db in try TriageEvent.fetchAll(db) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].priority, "high")
        XCTAssertEqual(events[0].needsReply, true)
        XCTAssertEqual(events[0].triggeredBy, "rule")
        XCTAssertTrue(events[0].reason.hasPrefix("Rule:"))
    }

    // Test 2: suppress rule → no notification, no LLM call
    func testSuppressRuleNoNotification() async throws {
        let db = try makeDB()
        let mockLLM = TriageMockLLMClient()
        let nm = await NotificationManager()
        let engine = TriageEngine(db: db, llmClient: mockLLM, notificationManager: nm)
        let rule = makeRule(keywordPattern: "Hello", suppress: true)
        let messages = makeMessages()

        try await engine.triage(
            service: "imessage",
            conversationId: "conv1",
            conversationName: "Alice",
            messages: messages,
            rules: [rule]
        )

        XCTAssertEqual(mockLLM.callCount, 0, "LLM should not be called when suppress rule matches")

        let events = try await db.dbQueue.read { db in try TriageEvent.fetchAll(db) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].priority, "low")
        XCTAssertEqual(events[0].needsReply, false)
        XCTAssertEqual(events[0].triggeredBy, "rule")
        XCTAssertFalse(events[0].notified)
    }

    // Test 3: no matching rule → LLM is called
    func testLLMPathCalledWhenNoRuleMatches() async throws {
        let db = try makeDB()
        let mockLLM = TriageMockLLMClient()
        let nm = await NotificationManager()
        let engine = TriageEngine(db: db, llmClient: mockLLM, notificationManager: nm)
        let messages = makeMessages()

        try await engine.triage(
            service: "imessage",
            conversationId: "conv1",
            conversationName: "Alice",
            messages: messages,
            rules: []
        )

        XCTAssertEqual(mockLLM.callCount, 1, "LLM should be called when no rule matches")

        let events = try await db.dbQueue.read { db in try TriageEvent.fetchAll(db) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].priority, "high")
        XCTAssertEqual(events[0].needsReply, true)
        XCTAssertEqual(events[0].triggeredBy, "llm")
        XCTAssertEqual(events[0].reason, "Urgent request")
    }

    // Test 4: LLM failure → fallback event persisted
    func testLLMFailureFallback() async throws {
        let db = try makeDB()
        let mockLLM = TriageMockLLMClient()
        mockLLM.shouldFail = true
        let nm = await NotificationManager()
        let engine = TriageEngine(db: db, llmClient: mockLLM, notificationManager: nm)
        let messages = makeMessages()

        try await engine.triage(
            service: "imessage",
            conversationId: "conv1",
            conversationName: "Alice",
            messages: messages,
            rules: []
        )

        let events = try await db.dbQueue.read { db in try TriageEvent.fetchAll(db) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].priority, "medium")
        XCTAssertEqual(events[0].needsReply, false)
        XCTAssertEqual(events[0].reason, "Triage unavailable")
        XCTAssertEqual(events[0].triggeredBy, "fallback")
        XCTAssertFalse(events[0].notified)
    }
}
