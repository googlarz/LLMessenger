// LLMessengerTests/SignalCLIAdapterTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class SignalCLIAdapterTests: XCTestCase {

    // MARK: - group() helpers

    func testGroupEmptyRows() {
        let result = SignalCLIAdapter.group(rows: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testGroupSingleDM() {
        let tsMs: Int64 = 1_700_000_000_000
        let row: [String: DatabaseValue] = [
            "sender": "+491629053673".databaseValue,
            "recipient": "+491739048003".databaseValue,
            "body": "Hello".databaseValue,
            "timestamp": tsMs.databaseValue,
            "group_id": DatabaseValue.null
        ]
        let result = SignalCLIAdapter.group(rows: [row])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].type, .dm)
        XCTAssertEqual(result[0].messages[0].text, "Hello")
        XCTAssertEqual(result[0].messages[0].sender, "+491629053673")
    }

    func testGroupMultipleMessagesSameConversation() {
        let ts1: Int64 = 1_700_000_000_000
        let ts2: Int64 = 1_700_000_001_000
        let rows: [[String: DatabaseValue]] = [
            ["sender": "+4915100000001".databaseValue, "recipient": "+491739048003".databaseValue,
             "body": "First".databaseValue, "timestamp": ts1.databaseValue, "group_id": DatabaseValue.null],
            ["sender": "+4915100000001".databaseValue, "recipient": "+491739048003".databaseValue,
             "body": "Second".databaseValue, "timestamp": ts2.databaseValue, "group_id": DatabaseValue.null],
        ]
        let result = SignalCLIAdapter.group(rows: rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].messages.count, 2)
    }

    func testGroupGroupMessage() {
        let ts: Int64 = 1_700_000_000_000
        let row: [String: DatabaseValue] = [
            "sender": "+4915100000001".databaseValue,
            "recipient": DatabaseValue.null,
            "body": "Hey group!".databaseValue,
            "timestamp": ts.databaseValue,
            "group_id": "UiMIGOgYuhVAFLoZtWOZuXy4e2SUKc5pbAGNkTRuSWA=".databaseValue
        ]
        let result = SignalCLIAdapter.group(rows: [row])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].type, .group)
        XCTAssertEqual(result[0].messages[0].text, "Hey group!")
    }

    func testGroupEmptyGroupIDTreatedAsDM() {
        // signal-mcp sends group_id as "" for DMs, not NULL
        let tsMs: Int64 = 1_700_000_000_000
        let row: [String: DatabaseValue] = [
            "sender": "+4915100000001".databaseValue,
            "recipient": "+491739048003".databaseValue,
            "body": "Direct".databaseValue,
            "timestamp": tsMs.databaseValue,
            "group_id": "".databaseValue
        ]
        let result = SignalCLIAdapter.group(rows: [row])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].type, .dm)
        XCTAssertEqual(result[0].id, "+4915100000001")
    }

    func testGroupSkipsEmptyBody() {
        let row: [String: DatabaseValue] = [
            "sender": "+4915100000001".databaseValue,
            "recipient": "+491739048003".databaseValue,
            "body": "".databaseValue,
            "timestamp": Int64(1_700_000_000_000).databaseValue,
            "group_id": DatabaseValue.null
        ]
        XCTAssertTrue(SignalCLIAdapter.group(rows: [row]).isEmpty)
    }

    func testGroupPreservesConversationOrder() {
        let rows: [[String: DatabaseValue]] = [
            ["sender": "+111".databaseValue, "recipient": DatabaseValue.null,
             "body": "A".databaseValue, "timestamp": Int64(1000).databaseValue, "group_id": DatabaseValue.null],
            ["sender": "+222".databaseValue, "recipient": DatabaseValue.null,
             "body": "B".databaseValue, "timestamp": Int64(2000).databaseValue, "group_id": DatabaseValue.null],
        ]
        let result = SignalCLIAdapter.group(rows: rows)
        XCTAssertEqual(result.map(\.id), ["+111", "+222"])
    }

    func testTimestampConvertedCorrectly() {
        let tsMs: Int64 = 1_700_000_000_000
        let row: [String: DatabaseValue] = [
            "sender": "+4915100000001".databaseValue,
            "recipient": "+491739048003".databaseValue,
            "body": "hi".databaseValue,
            "timestamp": tsMs.databaseValue,
            "group_id": DatabaseValue.null
        ]
        let result = SignalCLIAdapter.group(rows: [row])
        let expected = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000)
        XCTAssertEqual(result[0].messages[0].timestamp, expected)
    }
}
