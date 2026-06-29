// LLMessengerTests/BriefJSONTests.swift
import XCTest
@testable import LLMessenger

final class BriefJSONTests: XCTestCase {

    private func decode(_ jsonString: String) throws -> BriefJSON {
        try JSONDecoder().decode(BriefJSON.self, from: Data(jsonString.utf8))
    }

    // MARK: - Field defaults

    func testDecodeMinimalCardDefaultsFields() throws {
        let json = """
        {"cards":[{"id":"x","headline":"H","counts":{"messages":1,"threads":1,"people":1}}]}
        """
        let card = try decode(json).cards.first!
        XCTAssertEqual(card.service, "unknown")
        XCTAssertEqual(card.priority, "low")
        XCTAssertEqual(card.actionItems, [])
        XCTAssertEqual(card.sourceMessageIds, [])
        XCTAssertTrue(card.quotes.isEmpty)
        XCTAssertNil(card.callback)
        XCTAssertNil(card.conversationTitle)
    }

    func testDecodeEmptyCardsArray() throws {
        let brief = try decode(#"{"cards":[]}"#)
        XCTAssertEqual(brief.cards.count, 0)
    }

    func testDecodeTopLevelTotals() throws {
        let json = """
        {"total_messages":7,"total_threads":3,"total_people":4,"cards":[]}
        """
        let brief = try decode(json)
        XCTAssertEqual(brief.totalMessages, 7)
        XCTAssertEqual(brief.totalThreads, 3)
        XCTAssertEqual(brief.totalPeople, 4)
    }

    // MARK: - Legacy keys (backward compat)

    func testDecodeLegacyConversationKeyFallback() throws {
        let json = """
        {"cards":[{"id":"x","headline":"H","conversation":"Alice",
                   "counts":{"messages":1,"threads":1,"people":1}}]}
        """
        let card = try decode(json).cards.first!
        XCTAssertEqual(card.conversationId, "Alice")
        XCTAssertEqual(card.conversationTitle, "Alice")
    }

    func testDecodeLegacyActionsKeyFallback() throws {
        let json = """
        {"cards":[{"id":"x","headline":"H","actions":["Do the thing"],
                   "counts":{"messages":1,"threads":1,"people":1}}]}
        """
        XCTAssertEqual(try decode(json).cards.first!.actionItems, ["Do the thing"])
    }

    func testNewKeyTakesPrecedenceOverLegacyConversation() throws {
        // If both conversationId and conversation are present, conversationId wins.
        let json = """
        {"cards":[{"id":"x","headline":"H","conversationId":"real-id","conversation":"legacy",
                   "counts":{"messages":1,"threads":1,"people":1}}]}
        """
        XCTAssertEqual(try decode(json).cards.first!.conversationId, "real-id")
    }

    // MARK: - Optional / null fields

    func testDecodeNullCallbackIsNil() throws {
        let json = """
        {"cards":[{"id":"x","headline":"H","callback":null,
                   "counts":{"messages":1,"threads":1,"people":1}}]}
        """
        XCTAssertNil(try decode(json).cards.first!.callback)
    }

    func testDecodeQuoteWithNullMessageIdDoesNotCrash() throws {
        let json = """
        {"cards":[{"id":"x","headline":"H",
                   "quotes":[{"messageId":null,"from":"Alice","time":"09:00","text":"hi"}],
                   "counts":{"messages":1,"threads":1,"people":1}}]}
        """
        let card = try decode(json).cards.first!
        XCTAssertEqual(card.quotes.count, 1)
        XCTAssertNil(card.quotes[0].messageId)
        XCTAssertEqual(card.quotes[0].from, "Alice")
    }

    // MARK: - Multi-card / multi-service

    func testDecodeMultipleCardsRetainServices() throws {
        let json = """
        {"cards":[
          {"id":"s1","service":"signal",   "headline":"H","counts":{"messages":1,"threads":1,"people":1}},
          {"id":"t1","service":"telegram", "headline":"H","counts":{"messages":1,"threads":1,"people":1}},
          {"id":"i1","service":"imessage", "headline":"H","counts":{"messages":1,"threads":1,"people":1}}
        ]}
        """
        let brief = try decode(json)
        XCTAssertEqual(brief.cards.count, 3)
        XCTAssertEqual(brief.cards.map(\.service), ["signal", "telegram", "imessage"])
    }

    // MARK: - Priority pass-through

    func testDecodeUnknownPriorityPassesThrough() throws {
        let json = """
        {"cards":[{"id":"x","headline":"H","priority":"urgent",
                   "counts":{"messages":1,"threads":1,"people":1}}]}
        """
        // Priority is stored as-is; validation is the BriefEngine's concern.
        XCTAssertEqual(try decode(json).cards.first!.priority, "urgent")
    }

    // MARK: - Round-trip

    func testFullRoundTrip() throws {
        let card = BriefCard(
            id: "signal-abc-1",
            service: "signal",
            conversationId: "abc123",
            conversationTitle: "Alice",
            headline: "Alice confirmed meeting",
            priority: "high",
            counts: BriefCardCounts(messages: 3, threads: 1, people: 2),
            summary: "Alice confirmed Thursday.",
            callback: nil,
            actionItems: ["Send agenda"],
            quotes: [BriefQuote(messageId: "m1", from: "Alice", time: "09:00", text: "Can you send it?")],
            sourceMessageIds: ["m1", "m2"]
        )
        let original = BriefJSON(totalMessages: 3, totalThreads: 1, totalPeople: 2, cards: [card])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BriefJSON.self, from: data)

        let c = try XCTUnwrap(decoded.cards.first)
        XCTAssertEqual(c.id, card.id)
        XCTAssertEqual(c.service, card.service)
        XCTAssertEqual(c.conversationId, card.conversationId)
        XCTAssertEqual(c.headline, card.headline)
        XCTAssertEqual(c.priority, card.priority)
        XCTAssertEqual(c.actionItems, card.actionItems)
        XCTAssertEqual(c.sourceMessageIds, card.sourceMessageIds)
        XCTAssertEqual(c.quotes.first?.text, card.quotes.first?.text)
    }

    // MARK: - Regression guards

    func testSourceMessageIdsNeverContainBracketPrefix() throws {
        // Regression: LLM sometimes returns "[id=m1]" instead of "m1".
        // The decoder just stores what it receives — this test confirms pure-JSON
        // IDs don't have the prefix. The harness fixture tests end-to-end.
        let json = """
        {"cards":[{"id":"x","headline":"H",
                   "sourceMessageIds":["m1","m2"],
                   "counts":{"messages":2,"threads":1,"people":1}}]}
        """
        let ids = try decode(json).cards.first!.sourceMessageIds
        for id in ids {
            XCTAssertFalse(id.hasPrefix("[id="), "sourceMessageId '\(id)' must not include [id= prefix")
            XCTAssertFalse(id.hasSuffix("]"), "sourceMessageId '\(id)' must not include trailing ]")
        }
    }

    func testConversationIdNeverContainsPipe() throws {
        // Regression: LLM sometimes includes display name: "abc123 | Alice".
        let json = """
        {"cards":[{"id":"x","headline":"H","conversationId":"abc123",
                   "counts":{"messages":1,"threads":1,"people":1}}]}
        """
        let convId = try decode(json).cards.first!.conversationId
        XCTAssertFalse(convId.contains("|"), "conversationId '\(convId)' must not include pipe or display name suffix")
    }

    // MARK: - Lenient extraction from raw LLM output (OpusPlus audit 2026-06-15)
    // Regression guards for the brief-pipeline findings: fence-with-trailing-prose was
    // dropped by the old end-anchored regex, and the view fallback leaked raw JSON.

    func testDecodeLenientAcceptsPlainJSON() {
        XCTAssertNotNil(BriefJSON.decodeLenient(from: #"{"cards":[]}"#))
    }

    func testDecodeLenientAcceptsFencedJSON() {
        XCTAssertNotNil(BriefJSON.decodeLenient(from: "```json\n{\"cards\":[]}\n```"))
    }

    func testDecodeLenientAcceptsFencedJSONWithTrailingProse() {
        // The old end-anchored `\n?```$` left the closing fence in place -> decode failed.
        XCTAssertNotNil(BriefJSON.decodeLenient(from: "```json\n{\"cards\":[]}\n```\nHope this helps!"))
    }

    func testDecodeLenientAcceptsLeadingProse() {
        XCTAssertNotNil(BriefJSON.decodeLenient(from: "Here is your brief: {\"cards\":[]}"))
    }

    func testDecodeLenientAcceptsTrailingProse() {
        XCTAssertNotNil(BriefJSON.decodeLenient(from: "{\"cards\":[]}\nLet me know if you need more."))
    }

    func testEmptyArrayMissingCloseBraceIsBalanced() {
        // The one truncation safely recovered: empty cards, only the outer brace missing.
        XCTAssertNotNil(BriefJSON.decodeLenient(from: #"{"cards":[]"#))
    }

    func testTruncatedBriefWithCardSafelyDecodesToNil() {
        // Realistic truncation (outer brace cut after a card). The engine's contract is to
        // DROP unrecoverable briefs, not half-render them, so this safely decodes to nil —
        // NOT a recovered partial brief. (OpusPlus caught a prior over-claim here.)
        XCTAssertNil(BriefJSON.decodeLenient(from: #"{"cards":[{"id":"a","headline":"H"}]"#))
    }

    func testTruncatedBriefStillFlaggedAsJSONSoFallbackSuppresses() {
        // Even when it can't decode, it must still read as JSON so the view fallback suppresses
        // it (never shows raw braces to the user) — the safe-degradation guarantee.
        XCTAssertTrue(BriefJSON.looksLikeJSON(#"{"cards":[{"id":"a","headline":"H"}]"#))
    }

    func testDecodeLenientRejectsPureProse() {
        XCTAssertNil(BriefJSON.decodeLenient(from: "Sorry, I can't help with that request."))
    }

    func testDecodeLenientNilOnEmptyOrNil() {
        XCTAssertNil(BriefJSON.decodeLenient(from: ""))
        XCTAssertNil(BriefJSON.decodeLenient(from: "   \n  "))
        XCTAssertNil(BriefJSON.decodeLenient(from: nil))
    }

    func testLooksLikeJSONFlagsRawFencedAndProseWrapped() {
        XCTAssertTrue(BriefJSON.looksLikeJSON(#"{"cards":[]}"#))
        XCTAssertTrue(BriefJSON.looksLikeJSON("```json\n{}\n```"))
        XCTAssertTrue(BriefJSON.looksLikeJSON("Here is your brief: {\"cards\":[]}"))
        XCTAssertTrue(BriefJSON.looksLikeJSON("{\"x\": 1}"))
    }

    func testLooksLikeJSONIgnoresPlainProse() {
        XCTAssertFalse(BriefJSON.looksLikeJSON("Just a plain prose summary, nothing structured."))
        XCTAssertFalse(BriefJSON.looksLikeJSON("Meet me at 5 {ish}"))
    }

    func testDecodeLenientHandlesStrayBraceInHeadline() {
        // Stray `{` inside a string value must not cause a spurious `}` to be appended.
        let json = #"{"cards":[{"id":"a","headline":"cost is {high","counts":{"messages":1,"threads":1,"people":1}}]}"#
        let brief = BriefJSON.decodeLenient(from: json)
        XCTAssertNotNil(brief, "Valid brief with stray { in headline should decode successfully")
        XCTAssertEqual(brief?.cards.first?.headline, "cost is {high")
    }

    func testDecodeLenientHandlesStrayBracketInHeadline() {
        // Stray `[` inside a string value must not cause a spurious `]` to be appended.
        let json = #"{"cards":[{"id":"b","headline":"see list [item","counts":{"messages":1,"threads":1,"people":1}}]}"#
        let brief = BriefJSON.decodeLenient(from: json)
        XCTAssertNotNil(brief, "Valid brief with stray [ in headline should decode successfully")
        XCTAssertEqual(brief?.cards.first?.headline, "see list [item")
    }
}
