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

    // MARK: - ok:false envelope handling

    private func makeWorkspace() -> SlackWorkspace {
        SlackWorkspace(teamId: "T01", teamName: "Acme", token: "xoxp-fake",
                       userId: "U1", userName: "Me")
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func stubResponse(json: String, status: Int32 = 200) {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Int(status),
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data(json.utf8))
        }
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // Slack signals failure via HTTP 200 + "ok": false — call() must throw a
    // specific, actionable error instead of silently returning an empty/default
    // decoded value that looks like "zero results" to the caller.
    func testAuthTestThrowsAuthFailedOnInvalidAuth() async {
        stubResponse(json: #"{"ok":false,"error":"invalid_auth"}"#)
        let client = SlackAPIClient(workspace: makeWorkspace(), session: mockSession())
        do {
            _ = try await client.authTest()
            XCTFail("Expected authTest to throw on ok:false invalid_auth")
        } catch SlackAPIError.authFailed(let code) {
            XCTAssertEqual(code, "invalid_auth")
        } catch {
            XCTFail("Expected SlackAPIError.authFailed, got \(error)")
        }
    }

    // A non-auth API error (e.g. rate limit body, or a method-specific error) must
    // be distinguished from an auth failure — it doesn't mean "reconnect."
    func testConversationsHistoryThrowsApiErrorOnNonAuthFailure() async {
        stubResponse(json: #"{"ok":false,"error":"channel_not_found"}"#)
        let client = SlackAPIClient(workspace: makeWorkspace(), session: mockSession())
        do {
            _ = try await client.conversationsHistory(channelId: "C1", oldestTs: nil)
            XCTFail("Expected conversationsHistory to throw on ok:false")
        } catch SlackAPIError.apiError(let code) {
            XCTAssertEqual(code, "channel_not_found")
        } catch {
            XCTFail("Expected SlackAPIError.apiError, got \(error)")
        }
    }

    // The old behavior (before this fix) silently decoded ok:false as an empty
    // page — this test guards against that regression by asserting it throws.
    func testUsersConversationsDoesNotSilentlyReturnEmptyOnAuthFailure() async {
        stubResponse(json: #"{"ok":false,"error":"token_revoked"}"#)
        let client = SlackAPIClient(workspace: makeWorkspace(), session: mockSession())
        do {
            _ = try await client.usersConversations()
            XCTFail("Expected usersConversations to throw rather than return silently")
        } catch SlackAPIError.authFailed(let code) {
            XCTAssertEqual(code, "token_revoked")
        } catch {
            XCTFail("Expected SlackAPIError.authFailed, got \(error)")
        }
    }

    func testChatPostMessageSucceedsOnOkTrue() async throws {
        stubResponse(json: #"{"ok":true}"#)
        let client = SlackAPIClient(workspace: makeWorkspace(), session: mockSession())
        try await client.chatPostMessage(channelId: "C1", text: "hi")   // must not throw
    }
}
