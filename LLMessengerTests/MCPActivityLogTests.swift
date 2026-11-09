// LLMessengerTests/MCPActivityLogTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class MCPActivityLogTests: XCTestCase {

    private final class Flags: @unchecked Sendable {
        var enabled = true
        var localOnly = false
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var flags: Flags!
    private var db: AppDatabase!
    private var server: MCPServer!
    private let callTime = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "mcp-activity-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        flags = Flags()
        db = try AppDatabase(inMemory: true)
        let flags = self.flags!
        let db = self.db!
        let callTime = self.callTime
        let toolbox = MCPToolbox(
            settings: MCPSettingsReader(isEnabled: { flags.enabled }, isGlobalLocalOnly: { flags.localOnly },
                                        enabledSince: { .distantPast }),
            openReader: { db }, openWriter: { db },
            now: { callTime },
            activity: MCPActivityLog(defaults: defaults))
        server = MCPServer(toolbox: toolbox)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func call(_ tool: String, _ arguments: [String: Any] = [:]) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ] as [String: Any])
        XCTAssertNotNil(server.handle(line: String(data: data, encoding: .utf8)!))
    }

    private var log: MCPActivityLog { MCPActivityLog(defaults: defaults) }

    func testRecordLoadClearRoundTrip() {
        XCTAssertNil(log.load())
        let when = Date(timeIntervalSince1970: 1_700_000_123)
        log.record(tool: "get_latest_digest", at: when)
        let loaded = log.load()
        XCTAssertEqual(loaded?.tool, "get_latest_digest")
        XCTAssertEqual(loaded?.date, when)
        log.record(tool: "search_messages", at: when.addingTimeInterval(5))
        XCTAssertEqual(log.load()?.tool, "search_messages")
        log.clear()
        XCTAssertNil(log.load())
    }

    func testSuccessfulCallRecordsToolAndTime() throws {
        try call("list_conversations")
        XCTAssertEqual(log.load()?.tool, "list_conversations")
        XCTAssertEqual(log.load()?.date, callTime)
    }

    func testNothingRecordedWhileMCPIsDisabled() throws {
        flags.enabled = false
        for tool in MCPToolbox.toolNames { try call(tool) }
        XCTAssertNil(log.load())
    }

    func testNothingRecordedForCallsRejectedBeforeReachingATool() throws {
        try call("not_a_tool")                       // unknown tool
        flags.localOnly = true
        try call("get_latest_digest")                // read tool refused by global Local-only mode
        let malformed = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["arguments": [String: Any]()],
        ] as [String: Any])
        _ = server.handle(line: String(data: malformed, encoding: .utf8)!)
        XCTAssertNil(log.load())
    }

    func testNoArgumentContentIsStored() throws {
        let secrets = ["SECRET-QUERY-8841", "SECRET-CONV-8842", "SECRET-TEXT-8843"]
        try call("search_messages", ["query": secrets[0]])
        try call("get_conversation_messages", ["service": "imessage", "conversation_id": secrets[1]])
        try call("propose_reply", ["service": "imessage", "conversation_id": secrets[1], "text": secrets[2]])

        let stored = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(Set(stored.keys), [MCPActivityLog.lastCallAtKey, MCPActivityLog.lastCallToolKey])
        let dump = String(describing: stored)
        for secret in secrets { XCTAssertFalse(dump.contains(secret), secret) }
        XCTAssertEqual(log.load()?.tool, "propose_reply")
    }
}
