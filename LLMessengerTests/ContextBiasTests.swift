// LLMessengerTests/ContextBiasTests.swift
import XCTest
import GRDB
@testable import LLMessenger

private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

private func makeContext(
    importantTopics: [String] = [],
    noiseTopics: [String] = [],
    keySenders: [String] = []
) -> ConversationContext {
    var ctx = ConversationContext(
        service: "imessage",
        conversationId: "conv1",
        label: "",
        priorityHint: "auto",
        updatedAt: Date()
    )
    ctx.importantTopicsList = importantTopics
    ctx.noiseTopicsList = noiseTopics
    ctx.keySendersList = keySenders
    return ctx
}

private func makeMessage(sender: String = "Alice", text: String = "Hello") -> Message {
    Message(
        id: nil, briefId: nil, service: "imessage", conversationId: "conv1",
        conversationName: "Alice", messageId: "msg0", sender: sender, text: text,
        timestamp: Date(), isSent: false
    )
}

final class ContextBiasTests: XCTestCase {

    // MARK: - Pure ContextBias logic

    func testKeySenderMatches() {
        let ctx = makeContext(keySenders: ["Coach"])
        XCTAssertEqual(ContextBias.matchingKeySender(sender: "Coach Lasse", context: ctx), "Coach")
        XCTAssertNil(ContextBias.matchingKeySender(sender: "Alice", context: ctx))
    }

    func testImportantTopicRaises() {
        let ctx = makeContext(importantTopics: ["deploy"])
        let base = TriageResult(priority: "low", needsReply: false, reason: "FYI")
        let biased = ContextBias.applyTopicBias(to: base, newestText: "the DEPLOY is broken", context: ctx)
        XCTAssertEqual(biased.priority, "medium")
        XCTAssertTrue(biased.reason.contains("Important topic"))
    }

    func testNoiseTopicLowers() {
        let ctx = makeContext(noiseTopics: ["memes"])
        let base = TriageResult(priority: "medium", needsReply: true, reason: "thread")
        let biased = ContextBias.applyTopicBias(to: base, newestText: "more memes lol", context: ctx)
        XCTAssertEqual(biased.priority, "low")
        XCTAssertTrue(biased.reason.contains("Noise topic"))
    }

    func testImportantBeatsNoise() {
        let ctx = makeContext(importantTopics: ["game"], noiseTopics: ["lol"])
        let base = TriageResult(priority: "low", needsReply: false, reason: "x")
        let biased = ContextBias.applyTopicBias(to: base, newestText: "game tonight lol", context: ctx)
        XCTAssertEqual(biased.priority, "medium")
    }

    func testNilContextUnchanged() {
        let base = TriageResult(priority: "medium", needsReply: true, reason: "x")
        let biased = ContextBias.applyTopicBias(to: base, newestText: "anything", context: nil)
        XCTAssertEqual(biased.priority, "medium")
        XCTAssertEqual(biased.reason, "x")
    }

    // MARK: - Integration through TriageEngine

    func testKeySenderShortCircuitsToHigh() async throws {
        let db = try makeDB()
        let mockLLM = TriageMockLLMClient()
        let nm = await NotificationManager()
        let ctx = makeContext(keySenders: ["Alice"])
        try await db.dbQueue.write { try ctx.insert($0) }
        let engine = TriageEngine(db: db, llmClient: mockLLM, notificationManager: nm)

        try await engine.triage(
            service: "imessage", conversationId: "conv1", conversationName: "Alice",
            messages: [makeMessage(sender: "Alice")], rules: []
        )

        XCTAssertEqual(mockLLM.callCount, 0, "key sender should short-circuit before the LLM")
        let events = try await db.dbQueue.read { try TriageEvent.fetchAll($0) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].priority, "high")
        XCTAssertEqual(events[0].triggeredBy, "context")
        XCTAssertTrue(events[0].reason.hasPrefix("Key sender:"))
    }

    func testNoContextIdenticalToPreP2Behavior() async throws {
        let db = try makeDB()
        let mockLLM = TriageMockLLMClient()  // default stub: high / needsReply / "Urgent request"
        let nm = await NotificationManager()
        let engine = TriageEngine(db: db, llmClient: mockLLM, notificationManager: nm)

        try await engine.triage(
            service: "imessage", conversationId: "conv1", conversationName: "Alice",
            messages: [makeMessage()], rules: []
        )

        XCTAssertEqual(mockLLM.callCount, 1)
        let events = try await db.dbQueue.read { try TriageEvent.fetchAll($0) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].priority, "high")
        XCTAssertEqual(events[0].needsReply, true)
        XCTAssertEqual(events[0].triggeredBy, "llm")
        XCTAssertEqual(events[0].reason, "Urgent request")
    }

    func testNoiseTopicLowersThroughEngine() async throws {
        let db = try makeDB()
        let mockLLM = TriageMockLLMClient()
        mockLLM.stubbedResponse = #"{"priority":"medium","needsReply":true,"reason":"chatter"}"#
        let nm = await NotificationManager()
        let ctx = makeContext(noiseTopics: ["memes"])
        try await db.dbQueue.write { try ctx.insert($0) }
        let engine = TriageEngine(db: db, llmClient: mockLLM, notificationManager: nm)

        try await engine.triage(
            service: "imessage", conversationId: "conv1", conversationName: "Alice",
            messages: [makeMessage(text: "more memes")], rules: []
        )

        let events = try await db.dbQueue.read { try TriageEvent.fetchAll($0) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].priority, "low")
        XCTAssertEqual(events[0].triggeredBy, "context")
    }
}
