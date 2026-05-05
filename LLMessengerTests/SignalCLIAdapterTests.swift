// LLMessengerTests/SignalCLIAdapterTests.swift
import XCTest
@testable import LLMessenger

final class SignalCLIAdapterTests: XCTestCase {

    func testParseDMLine() throws {
        let line = """
        {"envelope":{"source":"+12345","sourceNumber":"+12345","sourceName":"Alice","sourceDevice":1,"timestamp":1700000000000,"dataMessage":{"timestamp":1700000000000,"message":"Hello","expiresInSeconds":0,"viewOnce":false}}}
        """
        let convos = SignalCLIAdapter.parse(lines: [line])
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].id, "+12345")
        XCTAssertEqual(convos[0].type, .dm)
        XCTAssertEqual(convos[0].messages.count, 1)
        XCTAssertEqual(convos[0].messages[0].sender, "Alice")
        XCTAssertEqual(convos[0].messages[0].text, "Hello")
    }

    func testParseGroupLine() throws {
        let line = """
        {"envelope":{"source":"+12345","sourceName":"Alice","timestamp":1700000000000,"dataMessage":{"message":"Hi group","groupInfo":{"groupId":"abc123==","name":"My Group","type":"DELIVER"}}}}
        """
        let convos = SignalCLIAdapter.parse(lines: [line])
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].id, "abc123==")
        XCTAssertEqual(convos[0].type, .group)
        XCTAssertEqual(convos[0].name, "My Group")
        XCTAssertEqual(convos[0].messages[0].text, "Hi group")
    }

    func testSkipsNonDataMessageLines() {
        let receipt = """
        {"envelope":{"source":"+12345","timestamp":1700000000000,"receiptMessage":{"when":1700000000000,"isDelivery":true}}}
        """
        let convos = SignalCLIAdapter.parse(lines: [receipt])
        XCTAssertEqual(convos.count, 0)
    }

    func testSkipsMalformedLines() {
        let convos = SignalCLIAdapter.parse(lines: ["not json at all", ""])
        XCTAssertEqual(convos.count, 0)
    }

    func testGroupsMessagesFromSameConversation() {
        let line1 = """
        {"envelope":{"source":"+12345","sourceNumber":"+12345","sourceName":"Alice","sourceDevice":1,"timestamp":1700000000000,"dataMessage":{"timestamp":1700000000000,"message":"First","expiresInSeconds":0,"viewOnce":false}}}
        """
        let line2 = """
        {"envelope":{"source":"+12345","sourceNumber":"+12345","sourceName":"Alice","sourceDevice":1,"timestamp":1700000001000,"dataMessage":{"timestamp":1700000001000,"message":"Second","expiresInSeconds":0,"viewOnce":false}}}
        """
        let convos = SignalCLIAdapter.parse(lines: [line1, line2])
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].messages.count, 2)
    }

    func testFallsBackToSourceWhenNoSourceName() {
        let line = """
        {"envelope":{"source":"+12345","sourceNumber":"+12345","sourceDevice":1,"timestamp":1700000000000,"dataMessage":{"timestamp":1700000000000,"message":"Hi","expiresInSeconds":0,"viewOnce":false}}}
        """
        let convos = SignalCLIAdapter.parse(lines: [line])
        XCTAssertEqual(convos[0].messages[0].sender, "+12345")
    }
}
