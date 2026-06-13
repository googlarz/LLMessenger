// LLMessengerTests/ConversationToneTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class ConversationToneTests: XCTestCase {

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
        for (key, _) in defaults.dictionaryRepresentation()
        where key.hasPrefix("contextSuggestionsShown_") {
            defaults.removeObject(forKey: key)
        }
    }

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    // MARK: - 1. Migration / model round-trip

    func testToneColumnRoundTrips() throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let ctx = ConversationContext(service: "signal", conversationId: "c1",
                                      label: "Bff", priorityHint: "auto",
                                      updatedAt: fixedNow, tone: "casual, lots of emoji")
        try repo.upsertConversationContext(ctx)
        let saved = try repo.fetchConversationContext(service: "signal", conversationId: "c1")
        XCTAssertEqual(saved?.tone, "casual, lots of emoji")
    }

    func testToneNilByDefault() throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let ctx = ConversationContext(service: "signal", conversationId: "c2",
                                      label: "", priorityHint: "auto", updatedAt: fixedNow)
        try repo.upsertConversationContext(ctx)
        let saved = try repo.fetchConversationContext(service: "signal", conversationId: "c2")
        XCTAssertNil(saved?.tone)
    }

    // MARK: - 2. PromptBuilder rendering

    func testPromptRendersToneWhenSet() {
        let ctx = ConversationContext(service: "signal", conversationId: "c1",
                                      label: "Bff", priorityHint: "auto",
                                      updatedAt: fixedNow, tone: "casual, lots of emoji")
        let prompt = PromptBuilder.build(
            mode: .replyDrafter, basePrompt: "BASE", services: [], episodicSummaries: [],
            now: fixedNow, conversationContexts: [ctx]
        )
        XCTAssertTrue(prompt.contains("tone: casual, lots of emoji"))
    }

    func testPromptOmitsToneWhenNil() {
        let ctx = ConversationContext(service: "signal", conversationId: "c1",
                                      label: "Bff", priorityHint: "auto",
                                      updatedAt: fixedNow, relationship: "friend")
        let prompt = PromptBuilder.build(
            mode: .replyDrafter, basePrompt: "BASE", services: [], episodicSummaries: [],
            now: fixedNow, conversationContexts: [ctx]
        )
        XCTAssertFalse(prompt.contains("tone:"))
    }

    // MARK: - 3. Style-reference helper (draft auto-learn)

    func testStyleBlockIncludesSentMessagesAndTone() {
        let block = ChatViewModel.styleReferenceBlock(
            sentTexts: ["yo 😎", "lmk 🙌"], tone: "casual, emoji-friendly")
        XCTAssertTrue(block.contains("Preferred tone for this conversation: casual, emoji-friendly"))
        XCTAssertTrue(block.contains("style reference"))
        XCTAssertTrue(block.contains("yo 😎"))
    }

    func testStyleBlockEmptyWithNoSampleAndNoTone() {
        XCTAssertEqual(ChatViewModel.styleReferenceBlock(sentTexts: [], tone: nil), "")
    }

    // MARK: - 4. Emoji-density tone suggestion

    private func seedSent(_ db: AppDatabase, convId: String, name: String,
                          texts: [String]) throws {
        try db.dbQueue.write { grdb in
            for (i, t) in texts.enumerated() {
                let base = self.fixedNow.addingTimeInterval(Double(i) * 60)
                var m = Message(id: nil, briefId: nil, service: "imessage",
                                conversationId: convId, conversationName: name,
                                messageId: "\(convId)-s\(i)", sender: "Me", text: t,
                                timestamp: base, isSent: true)
                try m.insert(grdb)
            }
        }
    }

    func testEmojiHeavyConversationProducesToneSuggestion() async throws {
        let db = try makeDB()
        try seedSent(db, convId: "c1", name: "Mia",
                     texts: ["hey 😀", "lol 😂", "ok 👍", "nice 🎉", "sure ✅", "plain text"])
        let engine = RuleSuggestionEngine()
        let suggestions = try await engine.computeContextSuggestions(db: db, now: fixedNow)
        let tone = suggestions.filter { $0.kind == "tone" }
        XCTAssertEqual(tone.count, 1)
        XCTAssertEqual(tone[0].subject, "emoji-friendly")
        XCTAssertEqual(tone[0].id, "imessage|c1|tone")
    }

    func testPlainConversationProducesNoToneSuggestion() async throws {
        let db = try makeDB()
        try seedSent(db, convId: "c2", name: "Bob",
                     texts: ["hi", "ok", "sure", "thanks", "got it", "see you"])
        let engine = RuleSuggestionEngine()
        let suggestions = try await engine.computeContextSuggestions(db: db, now: fixedNow)
        XCTAssertTrue(suggestions.filter { $0.kind == "tone" }.isEmpty)
    }

    func testExistingToneSuppressesToneSuggestion() async throws {
        let db = try makeDB()
        try seedSent(db, convId: "c1", name: "Mia",
                     texts: ["hey 😀", "lol 😂", "ok 👍", "nice 🎉", "sure ✅"])
        let repo = BriefRepository(database: db)
        try repo.upsertConversationContext(ConversationContext(
            service: "imessage", conversationId: "c1", label: "", priorityHint: "auto",
            updatedAt: fixedNow, tone: "casual, emoji-friendly"))
        let engine = RuleSuggestionEngine()
        let suggestions = try await engine.computeContextSuggestions(db: db, now: fixedNow)
        XCTAssertTrue(suggestions.filter { $0.kind == "tone" }.isEmpty)
    }

    func testAcceptToneWritesContext() async throws {
        let db = try makeDB()
        try seedSent(db, convId: "c1", name: "Mia",
                     texts: ["hey 😀", "lol 😂", "ok 👍", "nice 🎉", "sure ✅"])
        let repo = BriefRepository(database: db)
        let engine = RuleSuggestionEngine()
        let suggestion = try await engine.computeContextSuggestions(db: db, now: fixedNow)
            .first { $0.kind == "tone" }!

        // Mirror AppState.acceptContextSuggestion's tone write.
        var ctx = (try repo.fetchConversationContext(service: suggestion.service,
                                                     conversationId: suggestion.conversationId))
            ?? ConversationContext(service: suggestion.service,
                                   conversationId: suggestion.conversationId,
                                   label: "", priorityHint: "auto", updatedAt: Date())
        ctx.tone = "casual, emoji-friendly"
        try repo.upsertConversationContext(ctx)

        let saved = try repo.fetchConversationContext(service: "imessage", conversationId: "c1")
        XCTAssertEqual(saved?.tone, "casual, emoji-friendly")
    }

    func testDismissSuppressesToneSuggestion() async throws {
        let db = try makeDB()
        try seedSent(db, convId: "c1", name: "Mia",
                     texts: ["hey 😀", "lol 😂", "ok 👍", "nice 🎉", "sure ✅"])
        let engine = RuleSuggestionEngine()
        let suggestion = try await engine.computeContextSuggestions(db: db, now: fixedNow)
            .first { $0.kind == "tone" }!
        await engine.dismissContext(suggestion: suggestion)

        let nextDay = fixedNow.addingTimeInterval(86400)
        let again = try await engine.computeContextSuggestions(db: db, now: nextDay)
        XCTAssertTrue(again.filter { $0.kind == "tone" }.isEmpty)
    }
}
