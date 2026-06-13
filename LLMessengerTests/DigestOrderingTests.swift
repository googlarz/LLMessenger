// LLMessengerTests/DigestOrderingTests.swift
import XCTest
@testable import LLMessenger

final class DigestOrderingTests: XCTestCase {

    private func card(_ id: String, conv: String, priority: String = "med",
                      headline: String = "h", summary: String = "s") -> BriefCard {
        BriefCard(
            id: id, service: "signal", conversationId: conv, conversationTitle: conv,
            headline: headline, priority: priority, counts: .zero, summary: summary,
            callback: nil, actionItems: [], quotes: [], sourceMessageIds: []
        )
    }

    private func context(conv: String, hint: String = "auto", noise: [String] = []) -> ConversationContext {
        var ctx = ConversationContext(
            service: "signal", conversationId: conv, label: "", priorityHint: hint, updatedAt: Date()
        )
        ctx.noiseTopicsList = noise
        return ctx
    }

    func testHighContextSortsAboveLow() {
        let cards = [card("a", conv: "low"), card("b", conv: "high")]
        let contexts = [context(conv: "low", hint: "low"), context(conv: "high", hint: "high")]
        let ordered = DigestOrdering.order(cards: cards, contexts: contexts)
        XCTAssertEqual(ordered.map { $0.card.id }, ["b", "a"])
    }

    func testLowContextIsCollapsed() {
        let cards = [card("a", conv: "low")]
        let ordered = DigestOrdering.order(cards: cards, contexts: [context(conv: "low", hint: "low")])
        XCTAssertTrue(ordered[0].collapsed)
    }

    func testNoiseDominatedIsCollapsed() {
        let cards = [card("a", conv: "memes", headline: "Daily meme dump", summary: "lots of memes today")]
        let ordered = DigestOrdering.order(cards: cards, contexts: [context(conv: "memes", noise: ["memes"])])
        XCTAssertTrue(ordered[0].collapsed)
    }

    func testFallsBackToCardPriorityWithoutContext() {
        let cards = [card("a", conv: "x", priority: "low"), card("b", conv: "y", priority: "high")]
        let ordered = DigestOrdering.order(cards: cards, contexts: [])
        XCTAssertEqual(ordered.map { $0.card.id }, ["b", "a"])
        XCTAssertFalse(ordered.contains { $0.collapsed })
    }
}
