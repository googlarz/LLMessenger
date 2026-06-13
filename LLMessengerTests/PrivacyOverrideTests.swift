// LLMessengerTests/PrivacyOverrideTests.swift
import XCTest
import GRDB
@testable import LLMessenger

/// Spy that records calls and declares itself a cloud client.
private final class CloudSpyLLMClient: LLMClient {
    var callCount = 0
    var isLocal: Bool { false }
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        callCount += 1
        return LLMResponse(text: """
        {"priority":"high","needsReply":true,"reason":"Urgent"}
        """, inputTokens: 1, outputTokens: 1)
    }
}

final class PrivacyOverrideTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func makeMessages() -> [Message] {
        [Message(
            id: nil, briefId: nil, service: "imessage",
            conversationId: "conv1", conversationName: "Alice",
            messageId: "m1", sender: "Alice", text: "hi",
            timestamp: Date(), isSent: false
        )]
    }

    private func saveContext(_ db: AppDatabase, privacyOverride: String?) async throws {
        try await db.dbQueue.write { grdb in
            let ctx = ConversationContext(
                service: "imessage", conversationId: "conv1",
                label: "", priorityHint: "auto", updatedAt: Date(),
                privacyOverride: privacyOverride
            )
            try ctx.save(grdb)
        }
    }

    func testLocalOnlyConversationNeverReachesCloudClient() async throws {
        let db = try makeDB()
        try await saveContext(db, privacyOverride: "local_only")
        let spy = CloudSpyLLMClient()
        let nm = await NotificationManager()
        let engine = TriageEngine(db: db, llmClient: spy, notificationManager: nm)

        try await engine.triage(
            service: "imessage", conversationId: "conv1",
            conversationName: "Alice", messages: makeMessages(), rules: []
        )

        XCTAssertEqual(spy.callCount, 0, "Cloud client must never be called for local_only")

        let events = try await db.dbQueue.read { grdb in try TriageEvent.fetchAll(grdb) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].triggeredBy, "privacy")
        XCTAssertEqual(events[0].priority, "medium")
        XCTAssertFalse(events[0].needsReply)
        XCTAssertTrue(events[0].reason.contains("Held local"))
    }

    func testNormalConversationStillCallsCloudClient() async throws {
        let db = try makeDB()
        try await saveContext(db, privacyOverride: nil)
        let spy = CloudSpyLLMClient()
        let nm = await NotificationManager()
        let engine = TriageEngine(db: db, llmClient: spy, notificationManager: nm)

        try await engine.triage(
            service: "imessage", conversationId: "conv1",
            conversationName: "Alice", messages: makeMessages(), rules: []
        )

        XCTAssertEqual(spy.callCount, 1, "Cloud client should be used for normal conversations")

        let events = try await db.dbQueue.read { grdb in try TriageEvent.fetchAll(grdb) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].triggeredBy, "llm")
    }
}
