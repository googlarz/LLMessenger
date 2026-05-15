import XCTest
@testable import LLMessenger

final class SlackAdapterTests: XCTestCase {

    // MARK: - Conversation ID round-trip

    func testEncodeDecodeConversationIDRoundTrip() {
        let encoded = SlackAdapter.encodeConversationID(teamId: "T01ABC", channelId: "C12XYZ")
        XCTAssertEqual(encoded, "T01ABC/C12XYZ")
        let decoded = SlackAdapter.decodeConversationID(encoded)
        XCTAssertEqual(decoded?.teamId, "T01ABC")
        XCTAssertEqual(decoded?.channelId, "C12XYZ")
    }

    func testDecodeRejectsMalformedIDs() {
        XCTAssertNil(SlackAdapter.decodeConversationID(""))
        XCTAssertNil(SlackAdapter.decodeConversationID("noseparator"))
    }

    func testDecodeKeepsChannelIDsContainingSlashes() {
        // maxSplits: 1 means anything after the first slash is one channelId component.
        // Slack channel IDs don't contain slashes today, but this guards future format drift.
        let decoded = SlackAdapter.decodeConversationID("TEAM/CHAN/EXTRA")
        XCTAssertEqual(decoded?.teamId, "TEAM")
        XCTAssertEqual(decoded?.channelId, "CHAN/EXTRA")
    }

    // MARK: - Timestamp parsing

    func testTsToDateParsesSlackTimestampFormat() {
        let date = SlackAdapter.tsToDate("1700000000.000100")
        XCTAssertNotNil(date)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1700000000.0001, accuracy: 0.01)
    }

    func testTsToDateReturnsNilForGarbage() {
        XCTAssertNil(SlackAdapter.tsToDate("not-a-timestamp"))
        XCTAssertNil(SlackAdapter.tsToDate(""))
    }

    // MARK: - buildConversation grouping

    private func makeUser(_ id: String, name: String) -> SlackAPIClient.UserInfo {
        SlackAPIClient.UserInfo(
            id: id, team_id: "T01", name: name,
            deleted: false,
            profile: .init(real_name: name, display_name: name, email: nil)
        )
    }

    func testBuildConversationDMUsesPartnerName() {
        let convo = SlackAPIClient.Conversation(
            id: "D1", name: nil, is_im: true, is_mpim: false, is_group: false,
            is_channel: false, is_private: false, is_archived: false,
            user: "U2", topic: nil
        )
        let users = [
            "U1": makeUser("U1", name: "Me"),
            "U2": makeUser("U2", name: "Alice")
        ]
        let msgs = [
            SlackAPIClient.HistoryMessage(ts: "1700000000.000100", user: "U2", bot_id: nil,
                                          text: "Hello", subtype: nil, username: nil),
            SlackAPIClient.HistoryMessage(ts: "1700000050.000200", user: "U1", bot_id: nil,
                                          text: "Hi back", subtype: nil, username: nil)
        ]
        let result = SlackAdapter.buildConversation(
            teamId: "T01", workspaceName: "Acme",
            convo: convo, messages: msgs, users: users, myUserId: "U1"
        )
        XCTAssertEqual(result.type, .dm)
        XCTAssertEqual(result.name, "Alice (Acme)")
        XCTAssertEqual(result.id, "T01/D1")
        XCTAssertEqual(result.messages.count, 2)
        // Outbound message marked correctly so isSent populates downstream.
        XCTAssertEqual(result.messages[0].sender, "Alice")
        XCTAssertFalse(result.messages[0].isFromMe)
        XCTAssertEqual(result.messages[1].sender, "Me")
        XCTAssertTrue(result.messages[1].isFromMe)
    }

    func testBuildConversationChannelPrefixesHash() {
        let convo = SlackAPIClient.Conversation(
            id: "C100", name: "general", is_im: false, is_mpim: false, is_group: false,
            is_channel: true, is_private: false, is_archived: false,
            user: nil, topic: nil
        )
        let msgs = [
            SlackAPIClient.HistoryMessage(ts: "1700000000.0", user: "U99", bot_id: nil,
                                          text: "hello world", subtype: nil, username: nil)
        ]
        let result = SlackAdapter.buildConversation(
            teamId: "T01", workspaceName: "Acme",
            convo: convo, messages: msgs, users: [:], myUserId: "U1"
        )
        XCTAssertEqual(result.type, .group)
        XCTAssertEqual(result.name, "#general (Acme)")
    }

    func testBuildConversationDropsMessagesWithoutUserOrText() {
        let convo = SlackAPIClient.Conversation(
            id: "C100", name: "general", is_im: false, is_mpim: false, is_group: false,
            is_channel: true, is_private: false, is_archived: false,
            user: nil, topic: nil
        )
        let msgs = [
            SlackAPIClient.HistoryMessage(ts: "1700000000.0", user: nil, bot_id: "B1",
                                          text: "bot text", subtype: nil, username: "bot"),
            SlackAPIClient.HistoryMessage(ts: "1700000001.0", user: "U2", bot_id: nil,
                                          text: "", subtype: nil, username: nil),
            SlackAPIClient.HistoryMessage(ts: "1700000002.0", user: "U2", bot_id: nil,
                                          text: "real message", subtype: nil, username: nil)
        ]
        let result = SlackAdapter.buildConversation(
            teamId: "T01", workspaceName: "Acme",
            convo: convo, messages: msgs, users: [:], myUserId: "U1"
        )
        XCTAssertEqual(result.messages.count, 1, "Bot messages without user and empty-text messages must be dropped")
        XCTAssertEqual(result.messages.first?.text, "real message")
    }
}
