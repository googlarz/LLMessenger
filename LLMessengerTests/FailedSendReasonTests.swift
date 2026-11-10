// LLMessengerTests/FailedSendReasonTests.swift
//
// The plain-language reason on a "Couldn't send" row is stored with the row, so
// it is still there after a restart (a fresh AppState on the same database).

import XCTest
@testable import LLMessenger

@MainActor
final class FailedSendReasonTests: XCTestCase {

    private func makeState(_ db: AppDatabase) -> AppState {
        AppState(database: db, llmClient: UnconfiguredLLMClient(), llmModel: "t", isLLMConfigured: false,
                 basePrompt: "", defaults: UserDefaults(suiteName: "FailedSendReasonTests-\(UUID().uuidString)")!)
    }

    func testReasonSurvivesARestartAndKeepsTheDraft() throws {
        let db = try AppDatabase(inMemory: true)
        let state = makeState(db)
        let action = AgentAction(
            id: nil, kind: AgentActionKind.reply.rawValue, service: "signal", conversationId: "c1",
            conversationName: "Alice", title: "Reply", payload: AgentAction.encodeReplyPayload("see you at 6"),
            reasoning: "agent draft", confidence: 0.8, riskLevel: "normal",
            status: AgentActionStatus.failed.rawValue, createdAt: Date(), resolvedAt: Date())
        let id = try XCTUnwrap(state.repository.insertAgentAction(action))
        let row = try XCTUnwrap(state.repository.fetchAgentAction(id: id))
        XCTAssertEqual(state.failureReason(for: row),
                       "Signal didn't accept the message. Check the connection in Settings → Services.", "Nothing recorded yet")

        state.trackedSendIDs.insert(id)
        let generic = "Signal didn't accept the message. Check the connection in Settings → Services."
        state.noteSettledSends([row])
        XCTAssertEqual(state.failureReason(for: row), generic)

        // "Restart": a new AppState, no in-memory reasons, same database.
        let restarted = makeState(db)
        let stored = try XCTUnwrap(restarted.repository.fetchAgentAction(id: id))
        XCTAssertTrue(restarted.sendFailureReasons.isEmpty)
        XCTAssertEqual(restarted.failureReason(for: stored), generic)
        XCTAssertEqual(stored.replyPayload?.draftText, "see you at 6", "The draft is untouched")
    }

    func testOlderRowsWithoutAReasonStillShowTheGenericLine() throws {
        let state = makeState(try AppDatabase(inMemory: true))
        let old = AgentAction(
            id: 1, kind: "reply", service: "imessage", conversationId: "x", conversationName: "X", title: "t",
            payload: #"{"draftText":"hi"}"#, reasoning: "r", confidence: 1, riskLevel: "normal",
            status: "failed", createdAt: Date(), resolvedAt: Date())
        XCTAssertEqual(state.failureReason(for: old),
                       "iMessage didn't accept the message. Check the connection in Settings → Services.")
    }

    private func failedRow(_ state: AppState, service: String = "signal", conv: String = "c1") throws -> AgentAction {
        let action = AgentAction(
            id: nil, kind: AgentActionKind.reply.rawValue, service: service, conversationId: conv,
            conversationName: "Alice", title: "Reply", payload: AgentAction.encodeReplyPayload("hi"),
            reasoning: "r", confidence: 0.8, riskLevel: "normal",
            status: AgentActionStatus.failed.rawValue, createdAt: Date(), resolvedAt: Date())
        let id = try XCTUnwrap(state.repository.insertAgentAction(action))
        return try XCTUnwrap(state.repository.fetchAgentAction(id: id))
    }

    /// The send path's error lives in the app-wide banner, which another operation can
    /// overwrite before the asynchronous refresh reports the failure. Whatever is in the
    /// banner at that point must neither become this send's reason nor be cleared.
    func testUnrelatedBannerErrorIsNeitherAttachedNorCleared() throws {
        let state = makeState(try AppDatabase(inMemory: true))
        let row = try failedRow(state)
        let id = try XCTUnwrap(row.id)
        state.trackedSendIDs.insert(id)
        state.lastError = "Slack poll failed: rate limited"   // arrives between failure and refresh

        state.noteSettledSends([row])

        let reason = state.failureReason(for: row)
        XCTAssertFalse(reason.contains("Slack"), reason)
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("rate limited"), reason)
        XCTAssertTrue(reason.contains("Signal"), reason)
        XCTAssertEqual(state.lastError, "Slack poll failed: rate limited", "a banner this code didn't set stays")
        let stored = try XCTUnwrap(state.repository.fetchAgentAction(id: id))
        XCTAssertEqual(stored.failureReason, reason)
    }

    func testDismissedBannerStillGivesTheServiceReason() throws {
        let state = makeState(try AppDatabase(inMemory: true))
        let row = try failedRow(state, service: "telegram")
        state.trackedSendIDs.insert(try XCTUnwrap(row.id))
        state.lastError = nil // the user dismissed it before the refresh landed

        state.noteSettledSends([row])

        XCTAssertEqual(state.failureReason(for: row),
                       "Telegram didn't accept the message. Check the connection in Settings → Services.")
    }

    func testTwoFailedSendsEachNameTheirOwnService() throws {
        let state = makeState(try AppDatabase(inMemory: true))
        let a = try failedRow(state, service: "signal", conv: "a")
        let b = try failedRow(state, service: "slack", conv: "b")
        state.trackedSendIDs.formUnion([try XCTUnwrap(a.id), try XCTUnwrap(b.id)])
        state.lastError = "Slack isn't connected." // belongs to B only, or to neither

        state.noteSettledSends([a, b])

        XCTAssertTrue(state.failureReason(for: a).hasPrefix("Signal"), state.failureReason(for: a))
        XCTAssertTrue(state.failureReason(for: b).hasPrefix("Slack"), state.failureReason(for: b))
        XCTAssertFalse(state.failureReason(for: a).contains("isn't connected"))
    }
}
