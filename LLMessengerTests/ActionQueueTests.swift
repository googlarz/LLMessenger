// LLMessengerTests/ActionQueueTests.swift
//
// P1: the agent proposes reply actions, respects privacy overrides, dedupes,
// and the queue can be approved/skipped. Risk-based batch approve only touches
// low-risk rows.

import XCTest
import GRDB
@testable import LLMessenger

final class ActionQueueTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "agentDisabled")
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.dismissedKey)
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.snoozedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "agentDisabled")
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.dismissedKey)
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.snoozedKey)
        super.tearDown()
    }

    private func seedOwedConversation(_ db: AppDatabase,
                                      conversationId: String = "c1",
                                      text: String = "Are you free tonight?") async throws {
        let now = Date()
        try await db.dbQueue.write { d in
            var m = Message(
                id: nil, briefId: nil, service: "imessage", conversationId: conversationId,
                conversationName: "Alice", messageId: "in-\(conversationId)", sender: "Alice",
                text: text, timestamp: now.addingTimeInterval(-3600), isSent: false)
            try m.insert(d)
        }
    }

    private func setContext(_ db: AppDatabase, conversationId: String = "c1", privacyOverride: String) throws {
        let ctx = ConversationContext(
            service: "imessage", conversationId: conversationId, label: "",
            priorityHint: "auto", updatedAt: Date(), privacyOverride: privacyOverride)
        try BriefRepository(database: db).upsertConversationContext(ctx)
    }

    private func draftJSON(_ text: String) -> String {
        #"{"title":"Reply","draftText":"\#(text)","reasoning":"answers her question","confidence":0.8}"#
    }

    // 1: proposes a reply action for an owed conversation
    func testProposesReplyForOwedConversation() async throws {
        let db = try makeDB()
        try await seedOwedConversation(db)
        let client = StubLLMClient(responses: [draftJSON("Yeah, free after 7!")])
        let engine = AgentEngine(db: db, llmClient: client, llmModel: "test",
                                 repository: BriefRepository(database: db), rulesProvider: { [] })
        await engine.trigger()
        let actions = try await db.dbQueue.read { d in try AgentAction.fetchAll(d) }
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.kindEnum, .reply)
        XCTAssertEqual(actions.first?.replyPayload?.draftText, "Yeah, free after 7!")
        XCTAssertEqual(actions.first?.statusEnum, .pending)
    }

    // 2: never_draft → no action
    func testNeverDraftProducesNoAction() async throws {
        let db = try makeDB()
        try await seedOwedConversation(db)
        try setContext(db, privacyOverride: "never_draft")
        let client = StubLLMClient(responses: [draftJSON("hi")])
        let engine = AgentEngine(db: db, llmClient: client, llmModel: "test",
                                 repository: BriefRepository(database: db), rulesProvider: { [] })
        await engine.trigger()
        let actions = try await db.dbQueue.read { d in try AgentAction.fetchAll(d) }
        XCTAssertTrue(actions.isEmpty)
        let calls = await client.callCount
        XCTAssertEqual(calls, 0)
    }

    // 3: local_only + cloud client → no action
    func testLocalOnlyWithCloudClientProducesNoAction() async throws {
        let db = try makeDB()
        try await seedOwedConversation(db)
        try setContext(db, privacyOverride: "local_only")
        let client = StubLLMClient(responses: [draftJSON("hi")])  // isLocal == false
        let engine = AgentEngine(db: db, llmClient: client, llmModel: "test",
                                 repository: BriefRepository(database: db), rulesProvider: { [] })
        await engine.trigger()
        let actions = try await db.dbQueue.read { d in try AgentAction.fetchAll(d) }
        XCTAssertTrue(actions.isEmpty)
    }

    // 4: dedupe — second cycle does not create a duplicate pending action
    func testDedupePendingPerConversation() async throws {
        let db = try makeDB()
        try await seedOwedConversation(db)
        let client = StubLLMClient(responses: [draftJSON("first"), draftJSON("second")])
        let engine = AgentEngine(db: db, llmClient: client, llmModel: "test",
                                 repository: BriefRepository(database: db), rulesProvider: { [] })
        await engine.trigger()
        await engine.trigger()
        let actions = try await db.dbQueue.read { d in try AgentAction.fetchAll(d) }
        XCTAssertEqual(actions.count, 1)
    }

    // 5: approve marks done (via repository, the path AppState uses)
    func testApproveMarksDone() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        try await db.dbQueue.write { d in
            var a = AgentAction(
                id: nil, kind: AgentActionKind.reply.rawValue, service: "imessage",
                conversationId: "c1", conversationName: "Alice", title: "t",
                payload: AgentAction.encodeReplyPayload("ok"), reasoning: "r",
                confidence: 0.5, riskLevel: "low", status: "pending",
                createdAt: Date(), resolvedAt: nil)
            try a.insert(d)
        }
        let id = try await db.dbQueue.read { d in try AgentAction.fetchOne(d)?.id }!
        try repo.updateAgentActionStatus(id: id, status: .done, resolvedAt: Date())
        let pending = try repo.fetchPendingAgentActions()
        XCTAssertTrue(pending.isEmpty)
        let row = try await db.dbQueue.read { d in try AgentAction.fetchOne(d) }
        XCTAssertEqual(row?.statusEnum, .done)
    }

    // 6: skip works
    func testSkipMarksSkipped() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        try await db.dbQueue.write { d in
            var a = AgentAction(
                id: nil, kind: "reply", service: "imessage", conversationId: "c1",
                conversationName: "Alice", title: "t", payload: "{}", reasoning: "r",
                confidence: 0.5, riskLevel: "normal", status: "pending",
                createdAt: Date(), resolvedAt: nil)
            try a.insert(d)
        }
        let id = try await db.dbQueue.read { d in try AgentAction.fetchOne(d)?.id }!
        try repo.updateAgentActionStatus(id: id, status: .skipped, resolvedAt: Date())
        XCTAssertTrue(try repo.fetchPendingAgentActions().isEmpty)
    }

    // 7: risk heuristics — link/money/new-recipient → high; short ack → low
    func testRiskHeuristics() {
        XCTAssertEqual(AgentEngine.riskLevel(draftText: "see http://x.com", triggerText: "?", hasSentHistory: true), .high)
        XCTAssertEqual(AgentEngine.riskLevel(draftText: "I'll pay you back", triggerText: "?", hasSentHistory: true), .high)
        XCTAssertEqual(AgentEngine.riskLevel(draftText: "hello there friend", triggerText: "hi", hasSentHistory: false), .high) // new recipient
        XCTAssertEqual(AgentEngine.riskLevel(draftText: "ok", triggerText: "you good?", hasSentHistory: true), .low)
        XCTAssertEqual(AgentEngine.riskLevel(
            draftText: "Sure, that works for me, see you then.",
            triggerText: "lunch at noon?", hasSentHistory: true), .normal)
    }
}

private actor StubLLMClient: LLMClient {
    var callCount = 0
    private var responses: [String]
    nonisolated var isLocal: Bool { false }

    init(responses: [String]) { self.responses = responses }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        callCount += 1
        let text = responses.isEmpty ? "" : responses.removeFirst()
        return LLMResponse(text: text, inputTokens: 0, outputTokens: 0)
    }
}
