// LLMessengerTests/MCPServerTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class MCPServerTests: XCTestCase {

    private final class Flags: @unchecked Sendable {
        var enabled = true
        var localOnly = false
        /// When MCP access was turned on; the default predates every seeded digest.
        var enabledSince: Date? = .distantPast
    }

    private var db: AppDatabase!
    private var flags: Flags!
    private var server: MCPServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.dismissedKey)
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.snoozedKey)
        db = try AppDatabase(inMemory: true)
        flags = Flags()
        let flags = self.flags!
        let db = self.db!
        let toolbox = MCPToolbox(
            settings: MCPSettingsReader(isEnabled: { flags.enabled },
                                        isGlobalLocalOnly: { flags.localOnly },
                                        enabledSince: { flags.enabledSince }),
            openReader: { db },
            openWriter: { db })
        server = MCPServer(toolbox: toolbox)
    }

    // MARK: - Seeding

    /// "open" is a normal chat; "secret" is local_only. Both mention "invoice" and end with a question.
    private func seed() throws {
        try insertMessage(conv: "open", name: "Alice", text: "Where is the invoice for March?", offset: -3600)
        try insertMessage(conv: "secret", name: "Therapist", text: "Did you pay the invoice for May?", offset: -1800)
        try db.dbQueue.write { grdb in
            try ConversationContext(service: "imessage", conversationId: "secret", label: "x",
                                    priorityHint: "auto", updatedAt: Date(),
                                    privacyOverride: "local_only").save(grdb)
            var brief = Brief(createdAt: Date(), status: "ready", services: "[]",
                              openingSummary: "mixed summary", notificationText: "mixed notification")
            try brief.insert(grdb)
            for (conv, title) in [("open", "Alice"), ("secret", "Therapist")] {
                try BriefCardRecord(id: "card-\(conv)", briefId: brief.id!, service: "imessage",
                                    conversationId: conv, conversationTitle: title,
                                    headline: "Headline \(conv)", priority: "high", summary: "Summary \(conv)",
                                    needsReply: true, actionItems: "[]", callbackText: nil,
                                    sourceMessageIds: "[]", createdAt: Date()).insert(grdb)
            }
        }
    }

    private func insertMessage(conv: String, name: String, text: String, offset: TimeInterval,
                               isSent: Bool = false) throws {
        try db.dbQueue.write { grdb in
            var m = Message(id: nil, briefId: nil, service: "imessage", conversationId: conv,
                            conversationName: name, messageId: "\(conv)-\(UUID().uuidString)",
                            sender: isSent ? "me" : name, text: text,
                            timestamp: Date().addingTimeInterval(offset), isSent: isSent)
            try m.insert(grdb)
        }
    }

    private func setPrivacy(_ conv: String, _ value: String) throws {
        try db.dbQueue.write { grdb in
            try ConversationContext(service: "imessage", conversationId: conv, label: "x",
                                    priorityHint: "auto", updatedAt: Date(),
                                    privacyOverride: value).save(grdb)
        }
    }

    // MARK: - Helpers

    private func rpc(_ object: [String: Any]) throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let response = server.handle(line: String(data: data, encoding: .utf8)!) else { return nil }
        XCTAssertFalse(response.contains("\n"), "responses must be single-line")
        return try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
    }

    private struct ToolOutput {
        let isError: Bool
        let text: String
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }
    }

    private func call(_ tool: String, _ args: [String: Any] = [:]) throws -> ToolOutput {
        let response = try XCTUnwrap(rpc(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                          "params": ["name": tool, "arguments": args]]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["type"] as? String, "text")
        return ToolOutput(isError: result["isError"] as? Bool ?? false,
                          text: content.first?["text"] as? String ?? "")
    }

    private func pendingActions() throws -> [AgentAction] {
        try db.dbQueue.read { try AgentAction.fetchAll($0) }
    }

    // MARK: - Protocol

    func testInitializeHandshakeShape() throws {
        let response = try XCTUnwrap(rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                          "params": ["protocolVersion": "2025-03-26", "capabilities": [:],
                                                     "clientInfo": ["name": "t", "version": "0"]]]))
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 1)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "llmessenger")
        XCTAssertFalse((info["version"] as? String ?? "").isEmpty)
    }

    func testInitializeFallsBackForUnknownProtocolVersion() throws {
        let response = try XCTUnwrap(rpc(["jsonrpc": "2.0", "id": "a", "method": "initialize",
                                          "params": ["protocolVersion": "1999-01-01"]]))
        XCTAssertEqual(response["id"] as? String, "a")
        XCTAssertEqual((response["result"] as? [String: Any])?["protocolVersion"] as? String, "2024-11-05")
    }

    func testNotificationsGetNoReply() throws {
        XCTAssertNil(try rpc(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNil(try rpc(["jsonrpc": "2.0", "method": "no/such/notification"]))
    }

    func testPingReturnsEmptyResult() throws {
        let response = try XCTUnwrap(rpc(["jsonrpc": "2.0", "id": 3, "method": "ping"]))
        XCTAssertEqual((response["result"] as? [String: Any])?.count, 0)
    }

    func testToolsListContainsAllSixTools() throws {
        flags.enabled = false   // listing must work while disabled
        let response = try XCTUnwrap(rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["get_owed_replies", "get_latest_digest", "search_messages",
                        "list_conversations", "get_conversation_messages", "propose_reply"])
        for tool in tools {
            XCTAssertNotNil(tool["inputSchema"])
            XCTAssertTrue((tool["description"] as? String ?? "").contains("untrusted"))
        }
    }

    func testUnknownMethodIsMinus32601() throws {
        let response = try XCTUnwrap(rpc(["jsonrpc": "2.0", "id": 9, "method": "resources/list"]))
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(response["id"] as? Int, 9)
    }

    func testMalformedJSONIsMinus32700() throws {
        let line = try XCTUnwrap(server.handle(line: "{not json"))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(response["id"] is NSNull)
    }

    func testUnknownToolIsInvalidParams() throws {
        let response = try XCTUnwrap(rpc(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                          "params": ["name": "send_message", "arguments": [:]]]))
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    // MARK: - Gating

    func testDisabledSettingBlocksEveryToolCall() throws {
        try seed()
        flags.enabled = false
        for tool in MCPToolbox.toolNames {
            let out = try call(tool, ["query": "invoice", "service": "imessage",
                                      "conversation_id": "open", "text": "hi"])
            XCTAssertTrue(out.isError, tool)
            XCTAssertTrue(out.text.contains("MCP access is disabled"), tool)
        }
        XCTAssertTrue(try pendingActions().isEmpty)
    }

    func testSettingIsReadFreshOnEachCall() throws {
        try seed()
        flags.enabled = false
        XCTAssertTrue(try call("list_conversations").isError)
        flags.enabled = true
        XCTAssertFalse(try call("list_conversations").isError)
    }

    func testGlobalLocalOnlyBlocksReadTools() throws {
        try seed()
        flags.localOnly = true
        let reads: [(String, [String: Any])] = [
            ("get_owed_replies", [:]), ("get_latest_digest", [:]),
            ("search_messages", ["query": "invoice"]), ("list_conversations", [:]),
            ("get_conversation_messages", ["service": "imessage", "conversation_id": "open"]),
        ]
        for (tool, args) in reads {
            let out = try call(tool, args)
            XCTAssertTrue(out.isError, tool)
            XCTAssertTrue(out.text.contains("Local-only mode"), tool)
        }
    }

    // MARK: - Per-conversation privacy

    func testLocalOnlyConversationNeverAppearsInAnyReadTool() throws {
        try seed()
        let outputs = [
            try call("get_owed_replies"),
            try call("get_latest_digest", ["limit": 5]),
            try call("search_messages", ["query": "invoice"]),
            try call("list_conversations"),
            try call("get_conversation_messages", ["service": "imessage", "conversation_id": "secret"]),
        ]
        for out in outputs {
            XCTAssertFalse(out.text.contains("secret"), out.text)
            XCTAssertFalse(out.text.contains("Therapist"), out.text)
            XCTAssertFalse(out.text.contains("May?"), out.text)
        }
        XCTAssertTrue(outputs[4].isError)
        // The non-private conversation is still served everywhere.
        XCTAssertEqual(outputs[0].json["count"] as? Int, 1)
        XCTAssertEqual(outputs[2].json["count"] as? Int, 1)
        XCTAssertEqual(outputs[3].json["count"] as? Int, 1)
        let digests = try XCTUnwrap(outputs[1].json["digests"] as? [[String: Any]])
        let cards = try XCTUnwrap(digests.first?["cards"] as? [[String: Any]])
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?["headline"] as? String, "Headline open")
        XCTAssertFalse(outputs[1].text.contains("mixed"), "brief-level text must not be exposed")
    }

    // MARK: - Digests made before MCP was turned on

    private func digestCount() throws -> (count: Int, note: String?) {
        let out = try call("get_latest_digest", ["limit": 5])
        XCTAssertFalse(out.isError)
        let digests = try XCTUnwrap(out.json["digests"] as? [[String: Any]])
        return (digests.count, out.json["note"] as? String)
    }

    func testDigestsCreatedBeforeMCPWasEnabledAreNotServed() throws {
        try seed() // brief created "now"
        flags.enabledSince = Date().addingTimeInterval(3600)
        let result = try digestCount()
        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(result.note?.contains("first digest generated after") == true)
    }

    func testDigestsCreatedAtOrAfterEnablingAreServed() throws {
        try seed()
        let brief = try db.dbQueue.read { try Brief.fetchOne($0) }
        flags.enabledSince = try XCTUnwrap(brief).createdAt // exactly at the boundary
        XCTAssertEqual(try digestCount().count, 1)
        flags.enabledSince = Date().addingTimeInterval(-3600)
        XCTAssertEqual(try digestCount().count, 1)
    }

    func testMissingEnabledSinceFailsClosedForDigests() throws {
        try seed()
        flags.enabledSince = nil
        let result = try digestCount()
        XCTAssertEqual(result.count, 0)
        XCTAssertNotNil(result.note)
    }

    func testSettingTimestampIsSetOnEnableAndClearedOnDisable() {
        let suite = UserDefaults(suiteName: "mcp-since-\(UUID().uuidString)")!
        let repo = SettingsRepository(userDefaults: suite)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(repo.loadMCPServerEnabledSince())
        repo.saveMCPServerEnabled(true, now: t1)
        XCTAssertEqual(repo.loadMCPServerEnabledSince(), t1)
        repo.saveMCPServerEnabled(true, now: t1.addingTimeInterval(500)) // no off→on transition
        XCTAssertEqual(repo.loadMCPServerEnabledSince(), t1)
        repo.saveMCPServerEnabled(false, now: t1.addingTimeInterval(600))
        XCTAssertNil(repo.loadMCPServerEnabledSince())
        repo.saveMCPServerEnabled(true, now: t1.addingTimeInterval(700))
        XCTAssertEqual(repo.loadMCPServerEnabledSince(), t1.addingTimeInterval(700))
    }

    func testServiceArgumentDescriptionMentionsWhatsApp() throws {
        let response = try XCTUnwrap(rpc(["jsonrpc": "2.0", "id": 3, "method": "tools/list"]))
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        var checked = 0
        for tool in tools {
            let props = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
            if let service = props?["service"] as? [String: Any] {
                checked += 1
                XCTAssertTrue((service["description"] as? String)?.contains("whatsapp") == true, tool["name"] as? String ?? "")
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testReadToolsReturnNormalData() throws {
        try seed()
        let msgs = try call("get_conversation_messages", ["service": "imessage", "conversation_id": "open"])
        XCTAssertFalse(msgs.isError)
        XCTAssertTrue(msgs.text.contains("invoice for March"))
        let search = try call("search_messages", ["query": "invoice", "service": "imessage", "limit": 1000])
        XCTAssertFalse(search.isError)
        let owed = try call("get_owed_replies")
        XCTAssertTrue(owed.text.contains("Alice"))
    }

    func testConversationMessagesAreOldestFirstAndLimited() throws {
        for i in 0..<5 {
            try insertMessage(conv: "open", name: "Alice", text: "msg \(i)", offset: TimeInterval(-100 + i))
        }
        let out = try call("get_conversation_messages",
                           ["service": "imessage", "conversation_id": "open", "limit": 3])
        let texts = (out.json["messages"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        XCTAssertEqual(texts, ["msg 2", "msg 3", "msg 4"])
    }

    // MARK: - propose_reply

    func testProposeReplyInsertsExactlyOnePendingReply() throws {
        try seed()
        let out = try call("propose_reply", ["service": "imessage", "conversation_id": "open",
                                             "text": "It is on its way."])
        XCTAssertFalse(out.isError, out.text)

        let actions = try pendingActions()
        XCTAssertEqual(actions.count, 1)
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.kind, AgentActionKind.reply.rawValue)
        XCTAssertEqual(action.statusEnum, .pending)
        XCTAssertEqual(action.replyPayload?.draftText, "It is on its way.")
        XCTAssertEqual(action.service, "imessage")
        XCTAssertEqual(action.conversationId, "open")
        XCTAssertEqual(action.conversationName, "Alice")
        XCTAssertTrue(action.isExternalProposal)
        XCTAssertEqual(action.title, "Reply to Alice (proposed by external agent)")
        XCTAssertNil(action.scheduledAt)
        XCTAssertNil(action.scheduledKind)
        XCTAssertNil(action.resolvedAt)
        XCTAssertFalse(action.isMaybe)
        XCTAssertEqual(out.json["queued"] as? Bool, true)
        XCTAssertEqual(out.json["replaced"] as? Bool, false)
        XCTAssertNil(out.json["action_id"], "must not leak the action count")
        // Nothing was stored as a sent message and no delegation was configured.
        let sent = try db.dbQueue.read { try Message.filter(Column("isSent") == true).fetchCount($0) }
        XCTAssertEqual(sent, 0)
        let delegated = try db.dbQueue.read {
            try ConversationContext.filter(Column("delegation") != nil).fetchCount($0)
        }
        XCTAssertEqual(delegated, 0)
    }

    func testProposeReplyRejectsNeverDraft() throws {
        try seed()
        try setPrivacy("open", "never_draft")
        let out = try call("propose_reply", ["service": "imessage", "conversation_id": "open", "text": "hi"])
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("Never draft"))
        XCTAssertTrue(try pendingActions().isEmpty)
    }

    func testProposeReplyRejectsUnknownConversation() throws {
        try seed()
        let out = try call("propose_reply", ["service": "imessage", "conversation_id": "nope", "text": "hi"])
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("not found"))
        XCTAssertTrue(try pendingActions().isEmpty)
    }

    func testProposeReplyLocalOnlyIsIndistinguishableFromUnknown() throws {
        try seed()
        let hidden = try call("propose_reply", ["service": "imessage", "conversation_id": "secret", "text": "hi"])
        let unknown = try call("propose_reply", ["service": "imessage", "conversation_id": "nope", "text": "hi"])
        XCTAssertTrue(hidden.isError)
        XCTAssertEqual(hidden.text, "Conversation not found.")
        XCTAssertEqual(hidden.text, unknown.text)
        XCTAssertEqual(hidden.isError, unknown.isError)
        XCTAssertTrue(try pendingActions().isEmpty)
    }

    func testProposeReplyReplacesPendingExternalProposalForSameConversation() throws {
        try seed()
        let first = try call("propose_reply", ["service": "imessage", "conversation_id": "open", "text": "one"])
        let second = try call("propose_reply", ["service": "imessage", "conversation_id": "open", "text": "two"])
        XCTAssertEqual(first.json["replaced"] as? Bool, false)
        XCTAssertEqual(second.json["replaced"] as? Bool, true)
        let actions = try pendingActions()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.replyPayload?.draftText, "two")
        XCTAssertEqual(actions.first?.statusEnum, .pending)
    }

    func testProposeReplyDoesNotTouchAppsOwnDraftOrResolvedExternalRows() throws {
        try seed()
        try db.dbQueue.write { grdb in
            for (status, reasoning) in [("pending", "own draft"),
                                        ("done", AgentAction.externalAgentReasoning)] {
                var a = AgentAction(id: nil, kind: AgentActionKind.reply.rawValue, service: "imessage",
                                    conversationId: "open", conversationName: "Alice", title: "t",
                                    payload: AgentAction.encodeReplyPayload("old"), reasoning: reasoning,
                                    confidence: 0.5, riskLevel: "normal", status: status,
                                    createdAt: Date(), resolvedAt: nil)
                try a.insert(grdb)
            }
        }
        let out = try call("propose_reply", ["service": "imessage", "conversation_id": "open", "text": "new"])
        XCTAssertEqual(out.json["replaced"] as? Bool, false)
        XCTAssertEqual(try pendingActions().count, 3)
    }

    func testProposeReplyGlobalCapRefusesTwentyFirstConversation() throws {
        for i in 0..<21 { try insertMessage(conv: "c\(i)", name: "P\(i)", text: "hello?", offset: -100) }
        for i in 0..<20 {
            let out = try call("propose_reply", ["service": "imessage", "conversation_id": "c\(i)", "text": "r"])
            XCTAssertFalse(out.isError, out.text)
        }
        let refused = try call("propose_reply", ["service": "imessage", "conversation_id": "c20", "text": "r"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("Too many pending proposals"))
        XCTAssertEqual(try pendingActions().count, 20)
        // Replacing an existing one at the cap is still allowed.
        let replace = try call("propose_reply", ["service": "imessage", "conversation_id": "c3", "text": "again"])
        XCTAssertFalse(replace.isError, replace.text)
        XCTAssertEqual(replace.json["replaced"] as? Bool, true)
        XCTAssertEqual(try pendingActions().count, 20)
    }

    func testExternalProposalsAreNotBatchEligible() {
        func action(_ reasoning: String, status: String = "pending", risk: String = "normal") -> AgentAction {
            AgentAction(id: 1, kind: AgentActionKind.reply.rawValue, service: "imessage", conversationId: "x",
                        conversationName: "X", title: "t", payload: "{}", reasoning: reasoning,
                        confidence: 0.5, riskLevel: risk, status: status, createdAt: Date(), resolvedAt: nil)
        }
        XCTAssertTrue(action("own draft").isBatchEligible)
        XCTAssertFalse(action("own draft", risk: "high").isBatchEligible)
        XCTAssertFalse(action("own draft", status: "done").isBatchEligible)
        let external = action(AgentAction.externalAgentReasoning)
        XCTAssertTrue(external.isExternalProposal)
        XCTAssertFalse(external.isBatchEligible)
    }

    // MARK: - Framing limits

    func testOversizeLineIsRejectedAtDispatch() throws {
        let big = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"pad\":\""
            + String(repeating: "a", count: MCPServer.maxLineBytes) + "\"}"
        let line = try XCTUnwrap(server.handle(line: big))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertTrue(response["id"] is NSNull)
    }

    func testLineSplitterRejectsOversizeAndKeepsServing() {
        var splitter = MCPLineSplitter(maxLineBytes: 10)
        var items = splitter.feed(Array("ok1\n".utf8))
        items += splitter.feed(Array("0123456789ABCDEF".utf8))   // over the cap mid-line
        items += splitter.feed(Array("GHIJ\nok2\n".utf8))        // rest of the long line dropped
        items += splitter.feed(Array("0123456789\n".utf8))        // exactly at the cap: fine
        items += splitter.feed(Array("tail".utf8))
        items += splitter.finish()
        XCTAssertEqual(items, [.line("ok1"), .oversize, .line("ok2"), .line("0123456789"), .line("tail")])
    }

    // MARK: - Connection freshness

    func testEachCallOpensAFreshConnection() throws {
        final class Counter: @unchecked Sendable { var reads = 0; var writes = 0 }
        let counter = Counter()
        let db = self.db!
        try seed()
        let toolbox = MCPToolbox(
            settings: MCPSettingsReader(isEnabled: { true }, isGlobalLocalOnly: { false }),
            openReader: { counter.reads += 1; return db },
            openWriter: { counter.writes += 1; return db })
        _ = toolbox.call(tool: "list_conversations", arguments: [:])
        _ = toolbox.call(tool: "list_conversations", arguments: [:])
        _ = toolbox.call(tool: "propose_reply", arguments: ["service": "imessage", "conversation_id": "open", "text": "a"])
        _ = toolbox.call(tool: "propose_reply", arguments: ["service": "imessage", "conversation_id": "open", "text": "b"])
        XCTAssertEqual(counter.reads, 2)
        XCTAssertEqual(counter.writes, 2)
    }

    func testProposeReplyRejectsEmptyAndOversizeText() throws {
        try seed()
        for text in ["", "   \n "] {
            let out = try call("propose_reply", ["service": "imessage", "conversation_id": "open", "text": text])
            XCTAssertTrue(out.isError)
        }
        let atLimit = try call("propose_reply", ["service": "imessage", "conversation_id": "open",
                                                 "text": String(repeating: "a", count: 4000)])
        XCTAssertFalse(atLimit.isError)
        let over = try call("propose_reply", ["service": "imessage", "conversation_id": "open",
                                              "text": String(repeating: "a", count: 4001)])
        XCTAssertTrue(over.isError)
        XCTAssertEqual(try pendingActions().count, 1, "only the 4000-char proposal is stored")
    }

    func testProposeReplyRequiresArguments() throws {
        try seed()
        XCTAssertTrue(try call("propose_reply", ["service": "imessage", "text": "hi"]).isError)
        XCTAssertTrue(try call("propose_reply", ["service": "imessage", "conversation_id": "open"]).isError)
        XCTAssertTrue(try pendingActions().isEmpty)
    }

    func testMissingDatabaseGivesClearError() throws {
        let toolbox = MCPToolbox(
            settings: MCPSettingsReader(isEnabled: { true }, isGlobalLocalOnly: { false }),
            openReader: { throw MCPToolError(message: MCPToolbox.noDataMessage) },
            openWriter: { throw MCPToolError(message: MCPToolbox.noDataMessage) })
        let out = toolbox.call(tool: "list_conversations", arguments: [:])
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("no data yet"))
    }

    func testExistingPathInitNeverCreatesAFile() throws {
        let path = NSTemporaryDirectory() + "mcp-missing-\(UUID().uuidString).db"
        XCTAssertThrowsError(try AppDatabase(existingPath: path, readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testReadOnlyConnectionCannotWrite() throws {
        let path = NSTemporaryDirectory() + "mcp-ro-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try AppDatabase(path: path)
        let ro = try AppDatabase(existingPath: path, readOnly: true)
        XCTAssertThrowsError(try ro.dbQueue.write { try $0.execute(sql: "DELETE FROM messages") })
    }
}
