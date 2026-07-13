import XCTest
@testable import LLMessenger

final class BriefNotificationPolicyTests: XCTestCase {
    func testHeldBackDigestContentRequiresAtLeastOneUpdate() {
        XCTAssertNil(BriefNotificationPolicy.heldBackDigestContent(count: 0))
        XCTAssertEqual(
            BriefNotificationPolicy.heldBackDigestContent(count: 1)?.body,
            "1 routine update is ready to review"
        )
        XCTAssertEqual(
            BriefNotificationPolicy.heldBackDigestContent(count: 3)?.body,
            "3 routine updates are ready to review"
        )
    }

    func testContextPriorityOverrideMakesLowCardInterrupting() {
        let card = makeCard(priority: "low")

        let count = BriefNotificationPolicy.highPriorityCount(
            cards: [card],
            effectivePriority: { _ in "high" }
        )
        let content = BriefNotificationPolicy.content(
            cards: [card],
            defaultTitle: "New messages",
            defaultBody: "Routine summary",
            effectivePriority: { _ in "high" }
        )

        XCTAssertEqual(count, 1)
        XCTAssertEqual(content.title, "1 item needs review")
        XCTAssertTrue(content.body.contains("Because it matches what you marked important"))
    }

    func testReplyCardsTakePrecedenceAndExplainExplicitReason() {
        let review = makeCard(id: "review", headline: "Review this", priority: "high")
        let reply = makeCard(
            id: "reply",
            headline: "Answer Alice",
            priority: "med",
            needsReply: true,
            reason: "Direct question"
        )

        let content = BriefNotificationPolicy.content(
            cards: [review, reply],
            defaultTitle: "New messages",
            defaultBody: "Routine summary",
            effectivePriority: { $0.priority }
        )

        XCTAssertEqual(content.title, "1 reply needs you")
        XCTAssertEqual(content.body, "Answer Alice · Because direct question")
    }

    func testRoutineCardsUseDigestFallback() {
        let content = BriefNotificationPolicy.content(
            cards: [makeCard(priority: "low")],
            defaultTitle: "Morning Brief",
            defaultBody: "12 new messages",
            effectivePriority: { $0.priority }
        )

        XCTAssertEqual(content.title, "Morning Brief")
        XCTAssertEqual(content.body, "12 new messages")
    }

    private func makeCard(
        id: String = "card",
        headline: String = "Important update",
        priority: String,
        needsReply: Bool = false,
        reason: String? = nil
    ) -> BriefCard {
        BriefCard(
            id: id,
            service: "signal",
            conversationId: id,
            conversationTitle: "Alice",
            headline: headline,
            priority: priority,
            counts: BriefCardCounts(messages: 1, threads: 1, people: 1),
            summary: "Summary",
            callback: nil,
            needsReply: needsReply,
            reason: reason,
            grounding: "context",
            actionItems: [],
            quotes: [],
            sourceMessageIds: ["m1"]
        )
    }
}
