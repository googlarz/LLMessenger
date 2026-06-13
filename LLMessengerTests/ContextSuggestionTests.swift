// LLMessengerTests/ContextSuggestionTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class ContextSuggestionTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        clearDefaults()
    }

    override func tearDown() {
        clearDefaults()
        super.tearDown()
    }

    private func clearDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "dismissedContextSuggestions")
        // Clear any per-day budget keys.
        for (key, _) in defaults.dictionaryRepresentation()
        where key.hasPrefix("contextSuggestionsShown_") {
            defaults.removeObject(forKey: key)
        }
    }

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(inMemory: true)
    }

    /// Inserts a received message then a fast (within 5 min) sent reply, repeated `count` times,
    /// each batch spaced an hour apart so latencies don't collide.
    private func seedFastReplies(
        _ db: AppDatabase,
        service: String = "imessage",
        conversationId: String = "conv1",
        conversationName: String = "Alice",
        sender: String = "Alice",
        count: Int
    ) throws {
        try db.dbQueue.write { grdb in
            for i in 0..<count {
                let base = self.fixedNow.addingTimeInterval(Double(i) * 3600)
                var received = Message(
                    id: nil, briefId: nil, service: service,
                    conversationId: conversationId, conversationName: conversationName,
                    messageId: "\(conversationId)-r\(i)", sender: sender, text: "ping \(i)",
                    timestamp: base, isSent: false
                )
                try received.insert(grdb)
                var sent = Message(
                    id: nil, briefId: nil, service: service,
                    conversationId: conversationId, conversationName: conversationName,
                    messageId: "\(conversationId)-s\(i)", sender: "Me", text: "pong \(i)",
                    timestamp: base.addingTimeInterval(60), isSent: true
                )
                try sent.insert(grdb)
            }
        }
    }

    func testFastReplyPatternProducesKeySenderSuggestion() async throws {
        let db = try makeDB()
        try seedFastReplies(db, count: 5)
        let engine = RuleSuggestionEngine()

        let suggestions = try await engine.computeContextSuggestions(db: db, now: fixedNow)

        XCTAssertEqual(suggestions.count, 1)
        let s = suggestions[0]
        XCTAssertEqual(s.kind, "keySender")
        XCTAssertEqual(s.subject, "Alice")
        XCTAssertEqual(s.id, "imessage|conv1|keySender")
    }

    func testBelowThresholdProducesNothing() async throws {
        let db = try makeDB()
        try seedFastReplies(db, count: 4)
        let engine = RuleSuggestionEngine()

        let suggestions = try await engine.computeContextSuggestions(db: db, now: fixedNow)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testAcceptWritesKeySenderIntoContext() async throws {
        let db = try makeDB()
        try seedFastReplies(db, count: 5)
        let repo = BriefRepository(database: db)
        let engine = RuleSuggestionEngine()

        let suggestion = try await engine.computeContextSuggestions(db: db, now: fixedNow)[0]

        // Mirror AppState.acceptContextSuggestion's write.
        var ctx = (try repo.fetchConversationContext(service: suggestion.service,
                                                     conversationId: suggestion.conversationId))
            ?? ConversationContext(service: suggestion.service,
                                   conversationId: suggestion.conversationId,
                                   label: "", priorityHint: "auto", updatedAt: Date())
        var senders = ctx.keySendersList
        senders.append(suggestion.subject)
        ctx.keySendersList = senders
        try repo.upsertConversationContext(ctx)

        let saved = try repo.fetchConversationContext(service: "imessage", conversationId: "conv1")
        XCTAssertEqual(saved?.keySendersList, ["Alice"])
    }

    func testDismissSuppressesPermanently() async throws {
        let db = try makeDB()
        try seedFastReplies(db, count: 5)
        let engine = RuleSuggestionEngine()

        let suggestion = try await engine.computeContextSuggestions(db: db, now: fixedNow)[0]
        await engine.dismissContext(suggestion: suggestion)

        // Use a later day so budget doesn't interfere; dismissal must still suppress.
        let nextDay = fixedNow.addingTimeInterval(86400)
        let again = try await engine.computeContextSuggestions(db: db, now: nextDay)
        XCTAssertTrue(again.isEmpty)
    }

    func testDailyRateLimitCaps() async throws {
        let db = try makeDB()
        // 5 distinct conversations, each a qualifying key sender.
        for i in 0..<5 {
            try seedFastReplies(db,
                                conversationId: "conv\(i)",
                                conversationName: "Person\(i)",
                                sender: "Person\(i)",
                                count: 5)
        }
        let engine = RuleSuggestionEngine()

        let first = try await engine.computeContextSuggestions(db: db, now: fixedNow)
        XCTAssertEqual(first.count, 3, "Daily budget caps at 3")

        // Same day → budget exhausted.
        let second = try await engine.computeContextSuggestions(db: db, now: fixedNow)
        XCTAssertTrue(second.isEmpty)
    }
}
