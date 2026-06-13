// LLMessengerTests/RuleEvaluatorTests.swift
import XCTest
@testable import LLMessenger

final class RuleEvaluatorTests: XCTestCase {

    private func makeRule(
        contactPattern: String? = nil,
        keywordPattern: String? = nil,
        service: String? = nil,
        suppress: Bool = false,
        alwaysNotify: Bool = false,
        setPriority: String? = nil,
        sortOrder: Int = 0,
        quietStart: String? = nil,
        quietEnd: String? = nil
    ) -> PriorityRule {
        PriorityRule(
            id: nil,
            contactPattern: contactPattern,
            keywordPattern: keywordPattern,
            service: service,
            setPriority: setPriority,
            suppress: suppress,
            alwaysNotify: alwaysNotify,
            sortOrder: sortOrder,
            createdAt: Date(),
            quietStart: quietStart,
            quietEnd: quietEnd
        )
    }

    // MARK: Basic matching

    func testNoRulesReturnsNil() {
        let result = RuleEvaluator.evaluate(contactName: "Alice", service: "signal", messageText: "hello", rules: [])
        XCTAssertNil(result)
    }

    func testContactPatternMatch() {
        let rule = makeRule(contactPattern: "alice", alwaysNotify: true)
        let result = RuleEvaluator.evaluate(contactName: "Alice Smith", service: nil, messageText: "", rules: [rule])
        XCTAssertNotNil(result)
        if case .alwaysNotify = result?.action {} else { XCTFail("Expected alwaysNotify") }
    }

    func testContactPatternNoMatch() {
        let rule = makeRule(contactPattern: "bob", alwaysNotify: true)
        let result = RuleEvaluator.evaluate(contactName: "Alice Smith", service: nil, messageText: "", rules: [rule])
        XCTAssertNil(result)
    }

    func testKeywordPatternMatch() {
        let rule = makeRule(keywordPattern: "urgent", suppress: true)
        let result = RuleEvaluator.evaluate(contactName: "Anyone", service: nil, messageText: "This is urgent!", rules: [rule])
        XCTAssertNotNil(result)
        if case .suppress = result?.action {} else { XCTFail("Expected suppress") }
    }

    func testServiceFilterExcludes() {
        let rule = makeRule(service: "telegram", alwaysNotify: true)
        let result = RuleEvaluator.evaluate(contactName: "Alice", service: "signal", messageText: "hi", rules: [rule])
        XCTAssertNil(result)
    }

    func testServiceFilterMatches() {
        let rule = makeRule(service: "signal", alwaysNotify: true)
        let result = RuleEvaluator.evaluate(contactName: "Alice", service: "signal", messageText: "hi", rules: [rule])
        XCTAssertNotNil(result)
    }

    // MARK: Sort order

    func testFirstMatchingRuleWins() {
        let r1 = makeRule(contactPattern: "alice", suppress: true, sortOrder: 0)
        let r2 = makeRule(contactPattern: "alice", alwaysNotify: true, sortOrder: 1)
        let result = RuleEvaluator.evaluate(contactName: "Alice", service: nil, messageText: "", rules: [r2, r1])
        if case .suppress = result?.action {} else { XCTFail("Expected suppress (sortOrder 0 wins)") }
    }

    // MARK: Quiet hours

    func testQuietWindowSuppressesAlwaysNotify() {
        // 22:00 – 06:00 quiet window; test at 23:00
        let rule = makeRule(alwaysNotify: true, quietStart: "22:00", quietEnd: "06:00")
        let date = dateAt(hour: 23, minute: 0)
        let result = RuleEvaluator.evaluate(contactName: "Alice", service: nil, messageText: "", rules: [rule], at: date)
        XCTAssertNil(result, "alwaysNotify should be suppressed during quiet window")
    }

    func testQuietWindowDoesNotSuppressSuppress() {
        // Suppress rules are still active during quiet hours
        let rule = makeRule(suppress: true, quietStart: "22:00", quietEnd: "06:00")
        let date = dateAt(hour: 23, minute: 0)
        let result = RuleEvaluator.evaluate(contactName: "Alice", service: nil, messageText: "", rules: [rule], at: date)
        XCTAssertNotNil(result, "suppress rule should still fire during quiet window")
    }

    func testQuietWindowMidnightWrap() {
        // 22:00 – 06:00, test at 02:00 (should be in window)
        let rule = makeRule(alwaysNotify: true, quietStart: "22:00", quietEnd: "06:00")
        let date = dateAt(hour: 2, minute: 0)
        let result = RuleEvaluator.evaluate(contactName: "Alice", service: nil, messageText: "", rules: [rule], at: date)
        XCTAssertNil(result, "02:00 is inside 22:00–06:00 quiet window")
    }

    func testOutsideQuietWindowFiresRule() {
        // 22:00 – 06:00, test at 10:00 (outside)
        let rule = makeRule(alwaysNotify: true, quietStart: "22:00", quietEnd: "06:00")
        let date = dateAt(hour: 10, minute: 0)
        let result = RuleEvaluator.evaluate(contactName: "Alice", service: nil, messageText: "", rules: [rule], at: date)
        XCTAssertNotNil(result, "10:00 is outside quiet window, rule should fire")
    }

    // MARK: setPriority action

    func testSetPriorityAction() {
        let rule = makeRule(setPriority: "high")
        let result = RuleEvaluator.evaluate(contactName: "Alice", service: nil, messageText: "", rules: [rule])
        if case .setPriority(let p) = result?.action {
            XCTAssertEqual(p, "high")
        } else {
            XCTFail("Expected setPriority action")
        }
    }

    // MARK: Helpers

    private func dateAt(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return Calendar.current.date(from: comps) ?? Date()
    }
}
