// LLMessengerTests/CommitmentTests.swift
//
// P3: CommitmentDeriver extracts both directions from a mock-LLM conversation,
// dedupes against open commitments, markFulfilled/drop transitions, a due open
// commitment yields a follow_up AgentAction, and local_only + cloud is skipped.

import XCTest
import GRDB
@testable import LLMessenger

final class CommitmentTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func seedMessages(_ db: AppDatabase) throws {
        let now = Date()
        try db.dbQueue.write { d in
            var m1 = Message(
                id: nil, briefId: nil, service: "signal", conversationId: "c1",
                conversationName: "Bob", messageId: "m1", sender: "Me",
                text: "I'll send the photos tomorrow.", timestamp: now.addingTimeInterval(-7200), isSent: true)
            try m1.insert(d)
            var m2 = Message(
                id: nil, briefId: nil, service: "signal", conversationId: "c1",
                conversationName: "Bob", messageId: "m2", sender: "Bob",
                text: "Great, and I'll get you the cap table Wed.", timestamp: now.addingTimeInterval(-3600), isSent: false)
            try m2.insert(d)
        }
    }

    // MARK: - Extraction (both directions)

    func testDeriverExtractsBothDirections() async throws {
        let db = try makeDB()
        try seedMessages(db)
        let client = ScriptedLLMClient(response: """
        {"commitments": [
          {"direction": "i_owe", "what": "send the photos", "dueHint": "tomorrow", "evidenceMessageId": "m1"},
          {"direction": "they_owe", "what": "get the cap table", "dueHint": "Wed", "evidenceMessageId": "m2"}
        ]}
        """)
        let derived = try await CommitmentDeriver().derive(db: db, llmClient: client, llmModel: "test")
        XCTAssertEqual(derived.count, 2)
        XCTAssertTrue(derived.contains { $0.directionEnum == .iOwe && $0.what == "send the photos" })
        XCTAssertTrue(derived.contains { $0.directionEnum == .theyOwe && $0.what == "get the cap table" })
        // dueHint "tomorrow" parsed into a date.
        XCTAssertNotNil(derived.first { $0.what == "send the photos" }?.dueAt)
    }

    // MARK: - Dedupe

    func testDeriverDedupesAgainstOpenCommitments() async throws {
        let db = try makeDB()
        try seedMessages(db)
        let repo = BriefRepository(database: db)
        // Pre-existing open commitment with the same `what` (different case).
        try repo.insertCommitment(Commitment(
            id: nil, direction: CommitmentDirection.iOwe.rawValue, service: "signal",
            conversationId: "c1", conversationName: "Bob", what: "Send The Photos",
            dueAt: nil, evidenceMessageId: nil, status: CommitmentStatus.open.rawValue,
            createdAt: Date()))

        let client = ScriptedLLMClient(response: """
        {"commitments": [
          {"direction": "i_owe", "what": "send the photos", "dueHint": "", "evidenceMessageId": "m1"},
          {"direction": "they_owe", "what": "get the cap table", "dueHint": "", "evidenceMessageId": "m2"}
        ]}
        """)
        let derived = try await CommitmentDeriver().derive(db: db, llmClient: client, llmModel: "test")
        // Only the cap table is new; "send the photos" is deduped.
        XCTAssertEqual(derived.count, 1)
        XCTAssertEqual(derived.first?.what, "get the cap table")
    }

    // MARK: - Status transitions

    func testMarkFulfilledAndDrop() throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let id = try repo.insertCommitment(Commitment(
            id: nil, direction: CommitmentDirection.iOwe.rawValue, service: "signal",
            conversationId: "c1", conversationName: "Bob", what: "send the file",
            dueAt: nil, evidenceMessageId: nil, status: CommitmentStatus.open.rawValue,
            createdAt: Date()))
        try repo.updateCommitmentStatus(id: id, status: .fulfilled)
        XCTAssertTrue(try repo.fetchOpenCommitments().isEmpty)

        let id2 = try repo.insertCommitment(Commitment(
            id: nil, direction: CommitmentDirection.theyOwe.rawValue, service: "signal",
            conversationId: "c2", conversationName: "Eve", what: "review the doc",
            dueAt: nil, evidenceMessageId: nil, status: CommitmentStatus.open.rawValue,
            createdAt: Date()))
        try repo.updateCommitmentStatus(id: id2, status: .dropped)
        XCTAssertTrue(try repo.fetchOpenCommitments().isEmpty)
    }

    // MARK: - Due commitment → follow_up action

    func testDueCommitmentProducesFollowUpAction() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        // Open commitment due in the past.
        try repo.insertCommitment(Commitment(
            id: nil, direction: CommitmentDirection.theyOwe.rawValue, service: "signal",
            conversationId: "c1", conversationName: "Bob", what: "the cap table",
            dueAt: Date().addingTimeInterval(-3600), evidenceMessageId: nil,
            status: CommitmentStatus.open.rawValue, createdAt: Date().addingTimeInterval(-7200)))

        // No new commitments returned by the LLM this cycle.
        let client = ScriptedLLMClient(response: #"{"commitments": []}"#)
        let engine = AgentEngine(
            db: db, llmClient: client, llmModel: "test",
            repository: repo, rulesProvider: { [] })

        let produced = await engine.deriveCommitmentsAndProposeFollowUps()
        XCTAssertTrue(produced)

        let actions = try await db.dbQueue.read { d in try AgentAction.fetchAll(d) }
        XCTAssertEqual(actions.count, 1)
        let followUp = try XCTUnwrap(actions.first)
        XCTAssertEqual(followUp.kindEnum, .followUp)
        XCTAssertEqual(followUp.riskEnum, .normal, "follow_up is not delegatable")
        XCTAssertNotNil(followUp.commitmentId)

        // Re-running does not duplicate the pending follow-up.
        let producedAgain = await engine.deriveCommitmentsAndProposeFollowUps()
        XCTAssertFalse(producedAgain)
        let after = try await db.dbQueue.read { d in try AgentAction.fetchCount(d) }
        XCTAssertEqual(after, 1)
    }

    // MARK: - Privacy

    func testLocalOnlyConversationSkippedWithCloudClient() async throws {
        let db = try makeDB()
        try seedMessages(db)
        let repo = BriefRepository(database: db)
        try repo.upsertConversationContext(ConversationContext(
            service: "signal", conversationId: "c1", label: "", priorityHint: "auto",
            updatedAt: Date(), privacyOverride: "local_only"))

        let client = ScriptedLLMClient(response: """
        {"commitments": [{"direction": "i_owe", "what": "send the photos", "dueHint": "", "evidenceMessageId": "m1"}]}
        """)
        XCTAssertFalse(client.isLocal)
        let derived = try await CommitmentDeriver().derive(db: db, llmClient: client, llmModel: "test")
        XCTAssertTrue(derived.isEmpty, "local_only + cloud client must extract nothing")
        XCTAssertEqual(client.callCount, 0, "must not even call the cloud LLM")
    }

    // MARK: - Relative date parsing

    func testParseDueDate() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // A fixed Wednesday: 2026-06-10 is a Wednesday.
        let wed = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 9))!
        let startOfToday = cal.startOfDay(for: wed)
        func days(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: startOfToday)! }
        // Day-granularity hints resolve to the END of the target day (next midnight) so a
        // commitment due "today" is not already overdue the instant it is derived.
        XCTAssertEqual(CommitmentDeriver.parseDueDate("today", now: wed, calendar: cal), days(1))
        XCTAssertEqual(CommitmentDeriver.parseDueDate("tomorrow", now: wed, calendar: cal), days(2))
        // "Friday" from Wednesday → end of Friday (+3 days from today's midnight).
        XCTAssertEqual(CommitmentDeriver.parseDueDate("by Friday", now: wed, calendar: cal), days(3))
        XCTAssertNil(CommitmentDeriver.parseDueDate("soonish", now: wed, calendar: cal))
    }

    func testTodayCommitmentNotDueAtDerivation() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Mid-afternoon: with start-of-day parsing this would already be overdue.
        let wed = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 15))!
        let due = CommitmentDeriver.parseDueDate("today", now: wed, calendar: cal)
        XCTAssertNotNil(due)
        let c = Commitment(id: 1, direction: CommitmentDirection.iOwe.rawValue,
                           service: "signal", conversationId: "c1", conversationName: "C",
                           what: "send the deck", dueAt: due, evidenceMessageId: nil,
                           status: CommitmentStatus.open.rawValue, createdAt: wed)
        XCTAssertFalse(AgentEngine.isDue(c, now: wed),
                       "a commitment due 'today' must not be overdue the moment it is derived")
    }
}

// MARK: - Test double

/// A scripted LLM that returns a fixed response and records its calls. Cloud (not local).
final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
    private let response: String
    private(set) var callCount = 0
    nonisolated var isLocal: Bool { false }

    init(response: String) { self.response = response }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        callCount += 1
        return LLMResponse(text: response, inputTokens: 0, outputTokens: 0)
    }
}
