// LLMessengerTests/CalendarActionTests.swift
//
// P4: AgentEngine proposes a calendar_hold from a scheduling message, proposes
// nothing for a non-scheduling thread, and the approve gating path does not crash
// or write a real calendar event when access is unauthorized. NO real EventKit
// access is required — we test proposal + payload + gating only.

import XCTest
import GRDB
@testable import LLMessenger

final class CalendarActionTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func seedInbound(_ db: AppDatabase, text: String, conversationId: String = "c1") throws {
        try db.dbQueue.write { d in
            var m = Message(
                id: nil, briefId: nil, service: "signal", conversationId: conversationId,
                conversationName: "Bob", messageId: "m-\(conversationId)", sender: "Bob",
                text: text, timestamp: Date().addingTimeInterval(-3600), isSent: false)
            try m.insert(d)
        }
    }

    // MARK: - Proposal

    func testSchedulingMessageProposesCalendarHold() async throws {
        let db = try makeDB()
        try seedInbound(db, text: "Let's meet Thursday at 3pm for an hour.")
        let client = ScriptedLLMClient(response: """
        {"schedule": [{"title": "Sync with Bob", "startISO": "2026-06-11T15:00:00Z", "endISO": "2026-06-11T16:00:00Z", "isInvite": false}]}
        """)
        let engine = AgentEngine(
            db: db, llmClient: client, llmModel: "test",
            repository: BriefRepository(database: db), rulesProvider: { [] })

        let produced = await engine.proposeCalendarActions()
        XCTAssertTrue(produced)

        let actions = try await db.dbQueue.read { d in try AgentAction.fetchAll(d) }
        XCTAssertEqual(actions.count, 1)
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.kindEnum, .calendarHold)
        XCTAssertEqual(action.riskEnum, .normal, "calendar_hold is not delegatable")

        let payload = try XCTUnwrap(action.calendarPayload)
        XCTAssertEqual(payload.title, "Sync with Bob")
        XCTAssertNotNil(payload.start)
        XCTAssertNotNil(payload.end)
    }

    func testInviteProposesRSVP() async throws {
        let db = try makeDB()
        try seedInbound(db, text: "Can you join the kickoff call Friday 10am? Yes or no?")
        let client = ScriptedLLMClient(response: """
        {"schedule": [{"title": "Kickoff call", "startISO": "2026-06-12T10:00:00Z", "endISO": "2026-06-12T11:00:00Z", "isInvite": true}]}
        """)
        let engine = AgentEngine(
            db: db, llmClient: client, llmModel: "test",
            repository: BriefRepository(database: db), rulesProvider: { [] })

        _ = await engine.proposeCalendarActions()
        let fetched = try await db.dbQueue.read { d in try AgentAction.fetchOne(d) }
        let action = try XCTUnwrap(fetched)
        XCTAssertEqual(action.kindEnum, .rsvp)
        XCTAssertNotNil(action.calendarPayload?.replyText)
    }

    // MARK: - Conservatism

    func testNonSchedulingThreadProposesNothing() async throws {
        let db = try makeDB()
        try seedInbound(db, text: "Thanks for lunch, that was fun!")
        let client = ScriptedLLMClient(response: #"{"schedule": []}"#)
        let engine = AgentEngine(
            db: db, llmClient: client, llmModel: "test",
            repository: BriefRepository(database: db), rulesProvider: { [] })

        let produced = await engine.proposeCalendarActions()
        XCTAssertFalse(produced)
        let count = try await db.dbQueue.read { d in try AgentAction.fetchCount(d) }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Gating: unauthorized approve must not crash or write

    @MainActor
    func testApproveCalendarHoldWhenUnauthorizedLeavesPendingWithoutCrash() async throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let payload = AgentAction.CalendarPayload(
            title: "Sync", startISO: "2026-06-11T15:00:00Z",
            endISO: "2026-06-11T16:00:00Z", notes: nil, replyText: nil)
        let id = try await db.dbQueue.write { d -> Int64 in
            var a = AgentAction(
                id: nil, kind: AgentActionKind.calendarHold.rawValue, service: "signal",
                conversationId: "c1", conversationName: "Bob", title: "Sync",
                payload: AgentAction.encodeCalendarPayload(payload),
                reasoning: "proposed time", confidence: 0.6,
                riskLevel: AgentActionRisk.normal.rawValue,
                status: AgentActionStatus.pending.rawValue, createdAt: Date(), resolvedAt: nil)
            try a.insert(d)
            return a.id!
        }

        let appState = AppState(
            database: db, llmClient: SilentLLMClient(), llmModel: "test", basePrompt: "")
        // Force "denied" deterministically — the host may actually have calendar access.
        appState.calendarAccessOverrideForTesting = false
        let action = try XCTUnwrap(try repo.fetchAgentAction(id: id))

        // Access denied → approve must not create an event and must leave the row pending.
        appState.approveAction(action)
        // Let the Task settle.
        try await Task.sleep(nanoseconds: 200_000_000)

        let after = try XCTUnwrap(try repo.fetchAgentAction(id: id))
        XCTAssertEqual(after.statusEnum, .pending, "unauthorized calendar approve must leave the action pending")
    }

    // MARK: - Schedule JSON decode

    func testDecodeScheduleStripsFencesAndFiltersEmptyTitles() {
        let fenced = """
        ```json
        {"schedule": [{"title": "", "startISO": "x", "endISO": "y", "isInvite": false},
                      {"title": "Real", "startISO": "x", "endISO": "y", "isInvite": false}]}
        ```
        """
        let items = AgentEngine.decodeSchedule(fenced)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Real")
    }
}
