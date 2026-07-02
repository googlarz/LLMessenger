// LLMessengerTests/TokenEstimatorTests.swift
import XCTest
@testable import LLMessenger

final class TokenEstimatorTests: XCTestCase {

    func testEstimateScalesWithLength() {
        let short = TokenEstimator.estimate("hi")
        let long = TokenEstimator.estimate(String(repeating: "hello world ", count: 100))
        XCTAssertLessThan(short, long)
    }

    func testEstimateNeverReturnsZeroForNonEmptyText() {
        XCTAssertGreaterThanOrEqual(TokenEstimator.estimate("a"), 1)
    }

    private func makeMessage(text: String, minutesAgo: Double) -> Message {
        Message(briefId: nil, service: "signal", conversationId: "c1", messageId: UUID().uuidString,
               sender: "A", text: text, timestamp: Date().addingTimeInterval(-minutesAgo * 60), isSent: false)
    }

    // The core behavior change: a thread of short messages keeps MORE of them
    // than the old flat 100-row cap would allow (since they're cheap), while a
    // thread of long messages keeps FEWER (since 100 of them could blow the budget).
    func testShortMessagesKeepMoreThanLongMessagesUnderSameBudget() {
        let shortMessages = (0..<200).map { makeMessage(text: "ok", minutesAgo: Double(200 - $0)) }
        let longMessages = (0..<200).map {
            makeMessage(text: String(repeating: "word ", count: 50), minutesAgo: Double(200 - $0))
        }
        let budget = 500

        let shortSelected = TokenEstimator.selectWithinBudget(shortMessages, tokenBudget: budget, text: \.text)
        let longSelected = TokenEstimator.selectWithinBudget(longMessages, tokenBudget: budget, text: \.text)

        XCTAssertGreaterThan(shortSelected.count, longSelected.count)
    }

    func testSelectWithinBudgetKeepsMostRecentMessages() {
        let messages = (0..<10).map { makeMessage(text: "message \($0)", minutesAgo: Double(10 - $0)) }
        let selected = TokenEstimator.selectWithinBudget(messages, tokenBudget: 20, text: \.text)
        // Budget only fits a handful — must be the newest ones, still in chronological order.
        XCTAssertFalse(selected.isEmpty)
        XCTAssertEqual(selected.last?.text, "message 9")
        XCTAssertEqual(selected.map(\.timestamp), selected.map(\.timestamp).sorted(),
                       "Selected messages must remain chronologically ordered")
    }

    // A single message larger than the whole budget must still be returned —
    // zero context is worse than slightly over budget.
    func testSingleOversizedMessageIsStillReturned() {
        let huge = makeMessage(text: String(repeating: "x", count: 10_000), minutesAgo: 1)
        let selected = TokenEstimator.selectWithinBudget([huge], tokenBudget: 10, text: \.text)
        XCTAssertEqual(selected.count, 1)
    }

    func testHardCountCeilingBoundsSelectionEvenWithTinyMessages() {
        let messages = (0..<1000).map { makeMessage(text: "a", minutesAgo: Double(1000 - $0)) }
        let selected = TokenEstimator.selectWithinBudget(
            messages, tokenBudget: 1_000_000, hardCountCeiling: 50, text: \.text)
        XCTAssertEqual(selected.count, 50)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(TokenEstimator.selectWithinBudget([Message](), tokenBudget: 100, text: \.text).isEmpty)
    }
}
