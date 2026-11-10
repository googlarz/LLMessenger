// LLMessengerTests/LateUndoTests.swift
//
// Undo after the 5-second window. The send path claims the row (executing) when the
// countdown ends and the UI can lag behind until the network call returns. Undo must
// then say so, keep tracking the send and never claim "undone"; Undo within the
// window still sends nothing.

import XCTest
import GRDB
@testable import LLMessenger

/// An adapter whose send suspends until the test lets it finish.
private final class SuspendingSendAdapter: MessengerAdapter, @unchecked Sendable {
    func listContacts() async -> [Contact] { [] }
    let serviceID: String
    var healthStatus: AdapterHealthResult.Status = .ok
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    private(set) var sent: [String] = []

    init(serviceID: String) { self.serviceID = serviceID }
    func start() async throws {}
    func stop() {}
    func fetch(config: FetchConfig) async throws -> AdapterFetchResult { AdapterFetchResult(conversations: []) }
    func healthCheck() async -> AdapterHealthResult { AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil) }

    func send(conversationID: String, text: String) async throws {
        markStarted()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in park(c) }
        record(text)
    }

    private func markStarted() { lock.lock(); started = true; lock.unlock() }
    private func record(_ text: String) { lock.lock(); sent.append(text); lock.unlock() }
    private func park(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if released { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
    }

    func release() {
        lock.lock(); released = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }
}

@MainActor
final class LateUndoTests: XCTestCase {

    nonisolated(unsafe) private var savedKill: Any?
    nonisolated(unsafe) private var savedAgent: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedKill = UserDefaults.standard.object(forKey: AgentDelegation.killSwitchKey)
        savedAgent = UserDefaults.standard.object(forKey: AgentDelegation.agentDisabledKey)
        UserDefaults.standard.removeObject(forKey: AgentDelegation.killSwitchKey)
        UserDefaults.standard.removeObject(forKey: AgentDelegation.agentDisabledKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedKill, forKey: AgentDelegation.killSwitchKey)
        UserDefaults.standard.set(savedAgent, forKey: AgentDelegation.agentDisabledKey)
        try await super.tearDown()
    }

    private func makeState() throws -> AppState {
        let db = try AppDatabase(inMemory: true)
        let defaults = UserDefaults(suiteName: "LateUndoTests-\(UUID().uuidString)")!
        return AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "", defaults: defaults)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func status(_ state: AppState, _ id: Int64) -> AgentActionStatus? {
        (try? state.repository.fetchAgentAction(id: id))?.statusEnum
    }

    private func stageComposerReply(_ state: AppState, text: String) throws -> (id: Int64, staged: AgentAction) {
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let request = try XCTUnwrap(state.replyComposer)
        guard case .staged(let id) = state.sendFromComposer(request, text: text) else {
            throw XCTSkip("not staged")
        }
        return (id, try XCTUnwrap(state.repository.fetchAgentAction(id: id)))
    }

    func testCancelAfterTheClaimStillSendsAndNeverSaysUndone() async throws {
        let state = try makeState()
        let adapter = SuspendingSendAdapter(serviceID: "signal")
        state.adapters = ["signal": adapter]
        let (id, staged) = try stageComposerReply(state, text: "on my way")
        let undosBefore = state.productLoveMetrics.undoCount

        // The window ends: the sacred path claims the row and the send suspends.
        await state.fireManualApprovedSend(actionID: id)
        await waitUntil { adapter.started }
        XCTAssertEqual(status(state, id), .executing)

        // The user presses Undo on the stale snapshot the bar was still showing.
        let outcome = state.undoStagedSend(staged)

        XCTAssertEqual(outcome, .tooLate)
        XCTAssertEqual(status(state, id), .executing, "cancel must not touch a claimed row")
        XCTAssertNil(state.replyComposer, "nothing went back to the composer")
        XCTAssertEqual(state.userReceipt?.text, "Too late — it's already sending.")
        XCTAssertFalse(state.userReceipt?.text.localizedCaseInsensitiveContains("undone") ?? false)
        XCTAssertTrue(state.trackedSendIDs.contains(id), "the send is still tracked")
        XCTAssertEqual(state.productLoveMetrics.undoCount, undosBefore, "a failed undo is not an undo")

        adapter.release()
        await waitUntil { state.userReceipt?.text.hasPrefix("Sent to") == true }

        XCTAssertEqual(adapter.sent, ["on my way"])
        XCTAssertEqual(status(state, id), .done)
        XCTAssertEqual(state.userReceipt?.text, "Sent to Alice · Signal")
    }

    func testCancelWithinTheWindowSendsNothingAndReopensTheComposer() async throws {
        let state = try makeState()
        let adapter = SuspendingSendAdapter(serviceID: "signal")
        state.adapters = ["signal": adapter]
        let (id, staged) = try stageComposerReply(state, text: "oops")

        let outcome = state.undoStagedSend(staged)
        await state.fireManualApprovedSend(actionID: id) // a late timer must not send

        XCTAssertEqual(outcome, .undone)
        XCTAssertEqual(status(state, id), .skipped)
        XCTAssertFalse(adapter.started)
        XCTAssertFalse(state.trackedSendIDs.contains(id))
        XCTAssertEqual(state.replyComposer?.initialText, "oops")
        XCTAssertNotEqual(state.userReceipt?.text, "Too late — it's already sending.")
    }

    func testUndoIsOnlyOfferedWhileTheCountdownHasTimeLeft() throws {
        let state = try makeState()
        let (_, staged) = try stageComposerReply(state, text: "hi")
        let fireAt = try XCTUnwrap(staged.scheduledAt)

        XCTAssertTrue(staged.isUndoable(at: fireAt.addingTimeInterval(-1)))
        XCTAssertFalse(staged.isUndoable(at: fireAt), "at zero the send is claimed")
        XCTAssertFalse(staged.isUndoable(at: fireAt.addingTimeInterval(2)))

        var claimed = staged
        claimed.status = AgentActionStatus.executing.rawValue
        XCTAssertFalse(claimed.isUndoable(at: fireAt.addingTimeInterval(-1)))
    }
}
