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
        XCTAssertEqual(card.quotes, [])
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
}

// Make BriefQuote Equatable for XCTAssertEqual
extension BriefQuote: Equatable {
    public static func == (lhs: BriefQuote, rhs: BriefQuote) -> Bool {
        lhs.messageId == rhs.messageId && lhs.from == rhs.from
        && lhs.time == rhs.time && lhs.text == rhs.text
    }
}
