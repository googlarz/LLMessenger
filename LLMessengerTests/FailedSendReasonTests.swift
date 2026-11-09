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
        XCTAssertEqual(state.failureReason(for: row), "Signal didn't accept the message.", "Nothing recorded yet")

        state.trackedSendIDs.insert(id)
        state.lastError = "Signal isn't running. Open Signal and try again."
        state.noteSettledSends([row])
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.failureReason(for: row), "Signal isn't running. Open Signal and try again.")

        // "Restart": a new AppState, no in-memory reasons, same database.
        let restarted = makeState(db)
        let stored = try XCTUnwrap(restarted.repository.fetchAgentAction(id: id))
        XCTAssertTrue(restarted.sendFailureReasons.isEmpty)
        XCTAssertEqual(restarted.failureReason(for: stored), "Signal isn't running. Open Signal and try again.")
        XCTAssertEqual(stored.replyPayload?.draftText, "see you at 6", "The draft is untouched")
    }

    func testOlderRowsWithoutAReasonStillShowTheGenericLine() throws {
        let state = makeState(try AppDatabase(inMemory: true))
        let old = AgentAction(
            id: 1, kind: "reply", service: "imessage", conversationId: "x", conversationName: "X", title: "t",
            payload: #"{"draftText":"hi"}"#, reasoning: "r", confidence: 1, riskLevel: "normal",
            status: "failed", createdAt: Date(), resolvedAt: Date())
        XCTAssertEqual(state.failureReason(for: old), "iMessage didn't accept the message.")
    }
}
