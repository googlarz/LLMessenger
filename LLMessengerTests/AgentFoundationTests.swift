// LLMessengerTests/AgentFoundationTests.swift
//
// P0 foundation: v22 migration usable, models round-trip, audit log writes,
// engine start/stop + kill switch.

import XCTest
import GRDB
@testable import LLMessenger

final class AgentFoundationTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "agentDisabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "agentDisabled")
        super.tearDown()
    }

    // MARK: - Migration

    func testV22ColumnsUsable() throws {
        let db = try makeDB()
        let exists: (String) throws -> Bool = { table in
            try db.dbQueue.read { d in try d.tableExists(table) }
        }
        XCTAssertTrue(try exists("agentActions"))
        XCTAssertTrue(try exists("commitments"))
        XCTAssertTrue(try exists("actionAudit"))
        // delegation column added to conversationContexts
        let hasDelegation = try db.dbQueue.read { d in
            try d.columns(in: "conversationContexts").contains { $0.name == "delegation" }
        }
        XCTAssertTrue(hasDelegation)
    }

    // MARK: - Round-trip

    func testAgentActionRoundTrip() throws {
        let db = try makeDB()
        try db.dbQueue.write { d in
            var a = AgentAction(
                id: nil, kind: AgentActionKind.reply.rawValue, service: "imessage",
                conversationId: "c1", conversationName: "Alice", title: "Reply to Alice",
                payload: AgentAction.encodeReplyPayload("On my way!"),
                reasoning: "she asked when", confidence: 0.8,
                riskLevel: AgentActionRisk.low.rawValue,
                status: AgentActionStatus.pending.rawValue,
                createdAt: Date(), resolvedAt: nil)
            try a.insert(d)
        }
        let fetched = try db.dbQueue.read { d in try AgentAction.fetchAll(d) }
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.replyPayload?.draftText, "On my way!")
        XCTAssertEqual(fetched.first?.kindEnum, .reply)
        XCTAssertEqual(fetched.first?.riskEnum, .low)
    }

    func testCommitmentRoundTrip() throws {
        let db = try makeDB()
        try db.dbQueue.write { d in
            var c = Commitment(
                id: nil, direction: CommitmentDirection.iOwe.rawValue, service: "signal",
                conversationId: "c2", conversationName: "Bob", what: "send the file",
                dueAt: nil, evidenceMessageId: "m9", status: CommitmentStatus.open.rawValue,
                createdAt: Date())
            try c.insert(d)
        }
        let fetched = try db.dbQueue.read { d in try Commitment.fetchAll(d) }
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.directionEnum, .iOwe)
        XCTAssertEqual(fetched.first?.what, "send the file")
    }

    // MARK: - Audit log

    func testActionAuditLogWritesRow() throws {
        let db = try makeDB()
        try ActionAuditLog.record(
            db: db, kind: "reply", service: "imessage", conversationId: "c1",
            detail: "Sent: hi", trigger: .approved)
        let rows = try db.dbQueue.read { d in try ActionAuditRecord.fetchAll(d) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.trigger, "approved")
        XCTAssertEqual(rows.first?.detail, "Sent: hi")
    }

    // MARK: - Engine lifecycle + kill switch

    func testEngineStartStopTogglesRunning() async throws {
        let db = try makeDB()
        let engine = AgentEngine(
            db: db, llmClient: SilentLLMClient(), llmModel: "test",
            repository: BriefRepository(database: db), rulesProvider: { [] })
        var running = await engine.isRunning
        XCTAssertFalse(running)
        await engine.start()
        running = await engine.isRunning
        XCTAssertTrue(running)
        await engine.stop()
        running = await engine.isRunning
        XCTAssertFalse(running)
    }

    func testKillSwitchSkipsCycle() async throws {
        let db = try makeDB()
        let client = CountingLLMClient()
        // Seed an owed conversation so a non-killed cycle would call the LLM.
        try seedOwed(db)
        UserDefaults.standard.set(true, forKey: "agentDisabled")
        let engine = AgentEngine(
            db: db, llmClient: client, llmModel: "test",
            repository: BriefRepository(database: db), rulesProvider: { [] })
        await engine.trigger()
        let calls = await client.callCount
        XCTAssertEqual(calls, 0, "kill switch must skip the cycle entirely")
    }

    private func seedOwed(_ db: AppDatabase) throws {
        let now = Date()
        try db.dbQueue.write { d in
            var m = Message(
                id: nil, briefId: nil, service: "imessage", conversationId: "c1",
                conversationName: "Alice", messageId: "m1", sender: "Alice",
                text: "Are you free tonight?", timestamp: now.addingTimeInterval(-3600), isSent: false)
            try m.insert(d)
        }
    }
}

// MARK: - Test doubles

final class SilentLLMClient: LLMClient {
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        LLMResponse(text: "", inputTokens: 0, outputTokens: 0)
    }
}

actor CountingLLMClient: LLMClient {
    var callCount = 0
    nonisolated var isLocal: Bool { false }
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        callCount += 1
        return LLMResponse(text: "", inputTokens: 0, outputTokens: 0)
    }
}
