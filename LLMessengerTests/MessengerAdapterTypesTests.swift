import XCTest
@testable import LLMessenger

final class MessengerAdapterTypesTests: XCTestCase {

    func testFetchConfigByCount() {
        let config = FetchConfig(mode: .byCount(last: 25))
        if case .byCount(let n) = config.mode {
            XCTAssertEqual(n, 25)
        } else {
            XCTFail("Expected byCount")
        }
    }

    func testFetchConfigByTime() {
        let date = Date()
        let config = FetchConfig(mode: .byTime(since: date))
        if case .byTime(let since) = config.mode {
            XCTAssertEqual(since.timeIntervalSince1970, date.timeIntervalSince1970,
                           accuracy: 0.001)
        } else {
            XCTFail("Expected byTime")
        }
    }

    func testConversationDecoding() throws {
        let json = """
        {
            "id": "abc",
            "name": "João",
            "type": "dm",
            "messages": [
                {
                    "id": "msg_1",
                    "sender": "João",
                    "text": "hello",
                    "timestamp": "2026-05-05T20:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let conversation = try decoder.decode(AdapterConversation.self, from: json)
        XCTAssertEqual(conversation.id, "abc")
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages[0].sender, "João")
    }

    func testAdapterHealthResultStatus() {
        let ok = AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil)
        XCTAssertEqual(ok.status, .ok)

        let err = AdapterHealthResult(status: .error, reason: "timeout", retryAfter: 30)
        XCTAssertEqual(err.status, .error)
        XCTAssertEqual(err.reason, "timeout")
        XCTAssertEqual(err.retryAfter, 30)
    }
}
