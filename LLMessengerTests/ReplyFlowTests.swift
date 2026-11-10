// LLMessengerTests/ReplyFlowTests.swift
//
// The Reply composer and everything around a send: every entry point ends in
// the composer addressed to the right conversation; a composer send creates one
// pending action and stages it (never sends at once) through the same undo path
// as Act; the sent text is exactly the editor text; read-only services never
// create a sendable action; failed sends stay in Act and can be retried; the
// Act keyboard rules; error wording per source; and the caught-up state.

import AppKit
import XCTest
import GRDB
@testable import LLMessenger

private final class FailingSendAdapter: MessengerAdapter, @unchecked Sendable {
    func listContacts() async -> [Contact] { [] }
    let serviceID: String
    var healthStatus: AdapterHealthResult.Status = .ok
    let error: Error
    init(serviceID: String, error: Error) { self.serviceID = serviceID; self.error = error }
    func start() async throws {}
    func stop() {}
    func fetch(config: FetchConfig) async throws -> AdapterFetchResult { AdapterFetchResult(conversations: []) }
    func send(conversationID: String, text: String) async throws { throw error }
    func healthCheck() async -> AdapterHealthResult { AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil) }
}

@MainActor
final class ReplyFlowTests: XCTestCase {

    nonisolated(unsafe) private var savedKill: Any?
    nonisolated(unsafe) private var savedAgent: Any?

    override func setUp() async throws {
        try await super.setUp()
        // evaluateDelegation reads the kill switches from .standard; keep the
        // harness neutral and restore whatever was there.
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

    // MARK: - Fixture

    private func makeState(llm: LLMClient = MockLLMClient()) throws -> AppState {
        let db = try AppDatabase(inMemory: true)
        let defaults = UserDefaults(suiteName: "ReplyFlowTests-\(UUID().uuidString)")!
        let state = AppState(database: db, llmClient: llm, llmModel: "test", basePrompt: "", defaults: defaults)
        state.replyHandOff = { _, _ in XCTFail("hand-off must be stubbed by the test that expects it") }
        return state
    }

    private func seedMessage(_ state: AppState, service: String = "signal", conv: String = "c1",
                             name: String = "Alice", sender: String = "Alice", text: String = "Are you coming?") throws {
        try state.database.dbQueue.write { d in
            var m = Message(id: nil, briefId: nil, service: service, conversationId: conv,
                            conversationName: name, messageId: "\(conv)-\(UUID().uuidString)", sender: sender,
                            text: text, timestamp: Date().addingTimeInterval(-60), isSent: false)
            try m.insert(d)
        }
    }

    @discardableResult
    private func insertAction(_ state: AppState, kind: AgentActionKind = .reply, text: String,
                              risk: AgentActionRisk = .normal, isMaybe: Bool = false,
                              reasoning: String = "agent draft", service: String = "signal",
                              conv: String = "c1", name: String = "Alice") throws -> AgentAction {
        let action = AgentAction(
            id: nil, kind: kind.rawValue, service: service, conversationId: conv,
            conversationName: name, title: "Reply", payload: AgentAction.encodeReplyPayload(text),
            reasoning: reasoning, confidence: 0.7, riskLevel: risk.rawValue,
            status: AgentActionStatus.pending.rawValue, createdAt: Date(), resolvedAt: nil, isMaybe: isMaybe)
        let id = try XCTUnwrap(state.repository.insertAgentAction(action))
        return try XCTUnwrap(state.repository.fetchAgentAction(id: id))
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func status(_ state: AppState, _ id: Int64) -> AgentActionStatus? {
        (try? state.repository.fetchAgentAction(id: id))?.statusEnum
    }

    // MARK: - Every entry point ends in the composer

    func testOwedReplyEntryPointOpensComposerForThatConversation() throws {
        let state = try makeState()
        let owed = OwedReply(service: "telegram", conversationId: "coach", conversationName: "Coach",
                             triggerMessageId: "m1", triggerText: "Thursday 6pm?", triggeredAt: Date(),
                             reason: "needs reply", priorityRank: 2)
        guard case .compose(let item) = ActQueueRules.commandReturn(for: .owedReply(owed)) else {
            return XCTFail("⌘Return on an owed reply opens the composer")
        }
        XCTAssertEqual(item.id, ActItem.owedReply(owed).id)

        // What REPLY… / ⌘Return / the digest card's Reply all call:
        state.openReplyComposer(service: owed.service, conversationId: owed.conversationId,
                                conversationName: owed.conversationName)

        let request = try XCTUnwrap(state.replyComposer)
        XCTAssertEqual(request.service, "telegram")
        XCTAssertEqual(request.conversationId, "coach")
        XCTAssertEqual(request.recipientLine, "Coach · Telegram")
        XCTAssertEqual(request.initialText, "")
        XCTAssertNil(request.sourceActionID)
        XCTAssertTrue(try state.repository.fetchPendingAgentActions().isEmpty, "opening never queues anything")
    }

    func testEditOnActDraftOpensComposerOnThatAction() throws {
        let state = try makeState()
        let action = try insertAction(state, text: "on my way")

        state.openComposer(editing: action)

        let request = try XCTUnwrap(state.replyComposer)
        XCTAssertEqual(request.sourceActionID, action.id)
        XCTAssertEqual(request.initialText, "on my way")
        XCTAssertEqual(request.conversationId, "c1")
    }

    func testCommitmentFollowUpOpensComposerWithNudgeAndCommitmentLink() throws {
        let state = try makeState()
        let commitment = Commitment(id: 7, direction: CommitmentDirection.theyOwe.rawValue, service: "slack",
                                    conversationId: "ops", conversationName: "#launch-room",
                                    what: "the postmortem", dueAt: Date(), evidenceMessageId: nil,
                                    status: CommitmentStatus.open.rawValue, createdAt: Date())

        state.draftFollowUp(for: commitment)

        let request = try XCTUnwrap(state.replyComposer)
        XCTAssertEqual(request.service, "slack")
        XCTAssertEqual(request.conversationId, "ops")
        XCTAssertEqual(request.commitmentId, 7)
        XCTAssertTrue(request.initialText.contains("the postmortem"))
        XCTAssertTrue(try state.repository.fetchPendingAgentActions().isEmpty,
                      "the follow-up is not queued until the user presses Send")
    }

    func testAskDraftReviewAndSendOpensComposerPrefilled() throws {
        let state = try makeState()
        let chat = ChatViewModel(appState: state)
        let draft = ReplyDraft(id: UUID(), text: "see you at 6", serviceID: "imessage",
                               conversationID: "any;-;+4912345", senderName: "Mum")
        chat.threadItems = [.replyDraft(id: draft.id, draft: draft)]

        chat.reviewAndSend(draftID: draft.id)

        let request = try XCTUnwrap(state.replyComposer)
        XCTAssertEqual(request.recipientLine, "Mum · iMessage")
        XCTAssertEqual(request.initialText, "see you at 6")
    }

    func testAskDraftWithUnknownRecipientCannotBeReviewed() throws {
        let state = try makeState()
        let chat = ChatViewModel(appState: state)
        let draft = ReplyDraft(id: UUID(), text: "hi", serviceID: "signal", conversationID: "unknown", senderName: "")
        chat.threadItems = [.replyDraft(id: draft.id, draft: draft)]

        chat.reviewAndSend(draftID: draft.id)

        XCTAssertNil(state.replyComposer)
    }

    func testQuickReplyChipOpensComposerInsteadOfAskDraft() throws {
        let state = try makeState()
        let chat = ChatViewModel(appState: state)

        chat.applyQuickReply(QuickReply(label: "Yes", draft: "Yes, 1pm works"), cardID: "card",
                             service: "imessage", convId: "fam", convName: "Dad")

        XCTAssertEqual(state.replyComposer?.initialText, "Yes, 1pm works")
        XCTAssertEqual(state.replyComposer?.conversationId, "fam")
        XCTAssertTrue(chat.threadItems.isEmpty, "nothing is drafted into the Ask thread")
    }

    func testGroupConversationIsRecognised() throws {
        let state = try makeState()
        try seedMessage(state, service: "whatsapp", conv: "1203@g.us", name: "Parents", sender: "Ana")
        state.openReplyComposer(service: "whatsapp", conversationId: "1203@g.us", conversationName: "Parents")
        XCTAssertEqual(state.replyComposer?.isGroup, true)

        try seedMessage(state, service: "telegram", conv: "club", name: "Club", sender: "Ana")
        try seedMessage(state, service: "telegram", conv: "club", name: "Club", sender: "Ben")
        state.openReplyComposer(service: "telegram", conversationId: "club", conversationName: "Club")
        XCTAssertEqual(state.replyComposer?.isGroup, true, "two other senders means a group")

        try seedMessage(state, service: "signal", conv: "+491", name: "Anna", sender: "Anna")
        state.openReplyComposer(service: "signal", conversationId: "+491", conversationName: "Anna")
        XCTAssertEqual(state.replyComposer?.isGroup, false)
    }

    // MARK: - Composer send → one pending action, staged, never immediate

    func testComposerSendCreatesOnePendingActionAndStagesItWithoutSending() async throws {
        let state = try makeState()
        let spy = SendTestSpyAdapter(serviceID: "signal")
        state.adapters = ["signal": spy]
        try seedMessage(state)
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let model = ReplyComposerModel(request: try XCTUnwrap(state.replyComposer), appState: state)
        model.text = "Yes — leaving now"

        let outcome = model.submit()

        guard case .staged(let id) = outcome else { return XCTFail("expected a staged send, got \(outcome)") }
        let rows = try await state.database.dbQueue.read { try AgentAction.fetchAll($0) }
        XCTAssertEqual(rows.count, 1, "exactly one action")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.statusEnum, .scheduled)
        XCTAssertEqual(row.scheduledKindEnum, .manual)
        XCTAssertEqual(row.scheduledUndoWindow, AgentAction.manualApproveUndoWindow)
        XCTAssertTrue(row.isUserComposed)
        XCTAssertEqual(row.kindEnum, .reply)
        XCTAssertEqual(row.replyPayload?.draftText, "Yes — leaving now")
        XCTAssertTrue(spy.sentMessages.isEmpty, "a composer send must wait out the undo window")
        XCTAssertNil(state.replyComposer, "the composer closes once the send is staged")
        state.undoStagedSend(row)
    }

    func testSentTextIsExactlyTheEditorText() async throws {
        let state = try makeState()
        let spy = SendTestSpyAdapter(serviceID: "signal")
        state.adapters = ["signal": spy]
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let model = ReplyComposerModel(request: try XCTUnwrap(state.replyComposer), appState: state)
        let typed = "  Line one\nline two 🙂 — €12 at www.example.com  "
        model.text = typed

        guard case .staged(let id) = model.submit() else { return XCTFail("not staged") }
        await state.fireManualApprovedSend(actionID: id)
        await waitUntil { self.status(state, id) == .done }

        XCTAssertEqual(spy.sentMessages.map(\.text), [typed])
        XCTAssertEqual(spy.sentMessages.map(\.conversationID), ["c1"])
    }

    func testUndoReturnsTheReplyToTheComposerAndNeverSends() async throws {
        let state = try makeState()
        let spy = SendTestSpyAdapter(serviceID: "signal")
        state.adapters = ["signal": spy]
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let model = ReplyComposerModel(request: try XCTUnwrap(state.replyComposer), appState: state)
        model.text = "oops wrong chat"
        guard case .staged(let id) = model.submit() else { return XCTFail("not staged") }
        let staged = try XCTUnwrap(state.repository.fetchAgentAction(id: id))

        state.undoStagedSend(staged)
        await state.fireManualApprovedSend(actionID: id) // a late timer must not send

        XCTAssertEqual(status(state, id), .skipped, "an undone composer reply leaves no queue item behind")
        XCTAssertTrue(spy.sentMessages.isEmpty)
        let reopened = try XCTUnwrap(state.replyComposer, "Undo puts the text back in the composer")
        XCTAssertEqual(reopened.initialText, "oops wrong chat")
        XCTAssertEqual(reopened.conversationId, "c1")
    }

    func testUndoOnAgentDraftReturnsItToPending() throws {
        let state = try makeState()
        state.adapters = ["signal": SendTestSpyAdapter(serviceID: "signal")]
        let action = try insertAction(state, text: "on my way")
        state.stageSend(action)
        XCTAssertEqual(status(state, action.id!), .scheduled)

        state.undoStagedSend(try XCTUnwrap(state.repository.fetchAgentAction(id: action.id!)))

        XCTAssertEqual(status(state, action.id!), .pending)
        XCTAssertNil(state.replyComposer)
    }

    func testEditingAnActDraftStagesThatSameActionWithTheEditedText() async throws {
        let state = try makeState()
        let spy = SendTestSpyAdapter(serviceID: "signal")
        state.adapters = ["signal": spy]
        let action = try insertAction(state, text: "agent text")
        state.openComposer(editing: action)
        let model = ReplyComposerModel(request: try XCTUnwrap(state.replyComposer), appState: state)
        model.text = "my text"

        guard case .staged(let id) = model.submit() else { return XCTFail("not staged") }
        XCTAssertEqual(id, action.id)
        let count = try await state.database.dbQueue.read { try AgentAction.fetchCount($0) }
        XCTAssertEqual(count, 1, "no second action is created")
        await state.fireManualApprovedSend(actionID: id)
        await waitUntil { self.status(state, id) == .done }
        XCTAssertEqual(spy.sentMessages.map(\.text), ["my text"])
    }

    func testUserComposedReplyIsNeverDelegatedOrBatched() throws {
        let action = AgentAction.userComposed(service: "signal", conversationId: "c1", conversationName: "Alice",
                                              text: "ok", commitmentId: nil)
        var ctx = ConversationContext(service: "signal", conversationId: "c1", label: "",
                                      priorityHint: "auto", updatedAt: Date())
        ctx.delegationKinds = ["reply", "ack", "rsvp", "follow_up"]
        let decision = AgentDelegation.decide(action: action, context: ctx, isKnownRecipient: true, clientIsLocal: true)
        XCTAssertFalse(decision.autoSend)
        XCTAssertFalse(action.isBatchEligible)
        XCTAssertNotEqual(action.riskEnum, .low, "batchApproveLowRisk only touches low risk")
        XCTAssertFalse(action.isMaybe)
        let followUp = AgentAction.userComposed(service: "signal", conversationId: "c1", conversationName: "Alice",
                                                text: "any news?", commitmentId: 3)
        XCTAssertEqual(followUp.kindEnum, .followUp)
        XCTAssertFalse(AgentDelegation.decide(action: followUp, context: ctx, isKnownRecipient: true,
                                              clientIsLocal: true).autoSend)
    }

    func testEmptyTextNeverCreatesAnAction() throws {
        let state = try makeState()
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let request = try XCTUnwrap(state.replyComposer)
        XCTAssertEqual(state.sendFromComposer(request, text: "  \n "), .empty)
        XCTAssertEqual(try state.database.dbQueue.read { try AgentAction.fetchCount($0) }, 0)
    }

    func testClosingWithUnsentTextKeepsItForThatConversation() throws {
        let state = try makeState()
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let model = ReplyComposerModel(request: try XCTUnwrap(state.replyComposer), appState: state)
        model.text = "half a thought"

        model.cancel()
        XCTAssertNil(state.replyComposer)

        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        XCTAssertEqual(state.replyComposer?.initialText, "half a thought")
        state.openReplyComposer(service: "signal", conversationId: "c2", conversationName: "Bob")
        XCTAssertEqual(state.replyComposer?.initialText, "", "drafts are per conversation")
    }

    // MARK: - Read-only services

    func testReadOnlyServiceNeverCreatesASendableActionAndNeverReportsSent() throws {
        let state = try makeState()
        var handedOff: [(String, URL?)] = []
        state.replyHandOff = { handedOff.append(($0, $1)) }
        state.openReplyComposer(service: "whatsapp", conversationId: "4917012345@s.whatsapp.net",
                                conversationName: "Tom")
        let request = try XCTUnwrap(state.replyComposer)
        XCTAssertFalse(request.canSend)

        XCTAssertEqual(state.sendFromComposer(request, text: "hi"),
                       .failed(ServiceCapabilities.readOnlyMessage(for: "whatsapp")))
        let model = ReplyComposerModel(request: request, appState: state)
        model.text = "see you there"
        XCTAssertEqual(model.submit(), .handedOff)

        XCTAssertEqual(try state.database.dbQueue.read { try AgentAction.fetchCount($0) }, 0)
        XCTAssertEqual(handedOff.count, 1)
        XCTAssertEqual(handedOff.first?.0, "see you there")
        XCTAssertEqual(handedOff.first?.1?.absoluteString, "whatsapp://send?phone=4917012345")
        let receipt = try XCTUnwrap(state.userReceipt?.text)
        XCTAssertTrue(receipt.hasPrefix("Copied"))
        XCTAssertFalse(receipt.contains("Sent"))
    }

    func testWhatsAppGroupDeepLinkOnlyOpensTheApp() {
        XCTAssertEqual(ServiceDeepLink.url(service: "whatsapp", conversationId: "1203@g.us")?.absoluteString, "whatsapp://")
        XCTAssertFalse(ServiceDeepLink.opensExactChat(service: "whatsapp", conversationId: "1203@g.us"))
        XCTAssertTrue(ServiceDeepLink.opensExactChat(service: "whatsapp", conversationId: "4917012345@s.whatsapp.net"))
    }

    // MARK: - The Ask path cannot send

    func testChatViewModelHasNoSendPath() throws {
        let source = URL(fileURLWithPath: String(#filePath))
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LLMessenger/UI/ChatViewModel.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(code.contains(".send(conversationID"), "the Ask panel must never call adapter.send")
        XCTAssertFalse(code.contains("stageManualApprove"), "the Ask panel must never stage a send itself")
        XCTAssertFalse(code.contains("adapters["), "the Ask panel has no reason to touch adapters")
    }

    // MARK: - Outcomes: sent, couldn't send, try again

    func testSuccessfulSendSaysWhoAndWhere() async throws {
        let state = try makeState()
        state.adapters = ["signal": SendTestSpyAdapter(serviceID: "signal")]
        let action = try insertAction(state, text: "ok", name: "Mum")
        state.stageSend(action)

        await state.fireManualApprovedSend(actionID: action.id!)
        await waitUntil { state.userReceipt?.text.hasPrefix("Sent") == true }

        XCTAssertEqual(state.userReceipt?.text, "Sent to Mum · Signal")
    }

    func testFailedSendStaysInActWithAMessagingReasonAndCanBeRetried() async throws {
        let state = try makeState()
        state.adapters = ["slack": FailingSendAdapter(serviceID: "slack", error: SlackAPIError.authFailed(code: "invalid_auth"))]
        let action = try insertAction(state, text: "Got it — reviewing now", service: "slack", conv: "ops", name: "#launch-room")
        state.stageSend(action)

        await state.fireManualApprovedSend(actionID: action.id!)
        await waitUntil { !state.failedSends.isEmpty }

        XCTAssertEqual(state.failedSends.map(\.id), [action.id])
        XCTAssertEqual(try state.repository.fetchRecentFailedSends().map(\.id), [action.id])
        let reason = state.failureReason(for: action)
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("AI settings"), reason)
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("API key"), reason)
        XCTAssertTrue(reason.contains("Slack"), reason)
        XCTAssertTrue(reason.hasSuffix("Check the connection in Settings → Services."), reason)
        XCTAssertEqual(state.userReceipt?.tone, .problem)
        XCTAssertEqual(state.userReceipt?.text, "Couldn't send to #launch-room · Slack")

        let spy = SendTestSpyAdapter(serviceID: "slack")
        state.adapters = ["slack": spy]
        state.retryFailedSend(action)

        XCTAssertEqual(status(state, action.id!), .scheduled, "Try again re-stages through the undo window")
        XCTAssertTrue(spy.sentMessages.isEmpty)
        await state.fireManualApprovedSend(actionID: action.id!)
        await waitUntil { self.status(state, action.id!) == .done }
        XCTAssertEqual(spy.sentMessages.map(\.text), ["Got it — reviewing now"])
    }

    func testDismissedFailedSendLeavesAct() throws {
        let state = try makeState()
        let action = try insertAction(state, text: "x")
        try state.repository.updateAgentActionStatus(id: action.id!, status: .failed, resolvedAt: Date())
        XCTAssertEqual(try state.repository.fetchRecentFailedSends().count, 1)

        state.dismissFailedSend(action)

        XCTAssertEqual(status(state, action.id!), .skipped)
        XCTAssertTrue(try state.repository.fetchRecentFailedSends().isEmpty)
    }

    func testOldFailuresDoNotFloodAct() throws {
        let state = try makeState()
        let action = try insertAction(state, text: "x")
        try state.repository.updateAgentActionStatus(id: action.id!, status: .failed,
                                                     resolvedAt: Date().addingTimeInterval(-10 * 86_400))
        XCTAssertTrue(try state.repository.fetchRecentFailedSends().isEmpty)
    }

    // MARK: - Act keyboard rules

    func testCommandReturnRules() throws {
        let state = try makeState()
        let normal = try insertAction(state, text: "fine")
        let maybe = try insertAction(state, text: "maybe", isMaybe: true)
        let risky = try insertAction(state, text: "pay €40", risk: .high)
        let external = try insertAction(state, text: "from mcp", reasoning: AgentAction.externalAgentReasoning)
        var scheduled = normal
        scheduled.status = AgentActionStatus.scheduled.rawValue

        XCTAssertEqual(ActQueueRules.commandReturn(for: nil), .none, "no selection → no send")
        XCTAssertEqual(ActQueueRules.commandReturn(for: .agentAction(normal)), .stage(normal))
        XCTAssertEqual(ActQueueRules.commandReturn(for: .agentAction(maybe)), .confirm(maybe))
        XCTAssertEqual(ActQueueRules.commandReturn(for: .agentAction(risky)), .confirm(risky))
        XCTAssertEqual(ActQueueRules.commandReturn(for: .agentAction(external)), .compose(.agentAction(external)),
                       "an external agent's draft never sends from the row")
        XCTAssertEqual(ActQueueRules.commandReturn(for: .agentAction(scheduled)), .alreadySending)
    }

    func testSelectionIsByIdAndNeverSlidesOntoANeighbour() throws {
        let state = try makeState()
        let a = ActItem.agentAction(try insertAction(state, text: "a"))
        let b = ActItem.agentAction(try insertAction(state, text: "b"))
        let c = ActItem.agentAction(try insertAction(state, text: "c"))

        // Nothing is selected until the user moves: J selects the first row.
        XCTAssertEqual(ActQueueRules.moveSelection(from: nil, anchor: 0, by: 1, in: [a, b, c]), a.id)
        XCTAssertEqual(ActQueueRules.moveSelection(from: a.id, anchor: 0, by: 1, in: [a, b, c]), b.id)
        // A new row arriving above keeps the selection on the same item.
        XCTAssertEqual(ActQueueRules.retainedSelection(b.id, in: [c.id, a.id, b.id]), b.id)
        // After b was sent it leaves the queue: selection clears instead of landing on c.
        XCTAssertNil(ActQueueRules.retainedSelection(b.id, in: [a.id, c.id]))
        // The next J picks up where the user was (the row now in b's place).
        XCTAssertEqual(ActQueueRules.moveSelection(from: nil, anchor: 1, by: 1, in: [a, c]), c.id)
    }

    func testSingleKeyMonitorOnlyActsInTheKeyMainWindowWithNoSheet() {
        let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        typealias C = KeyboardShortcutMonitor.Coordinator
        XCTAssertTrue(C.accepts(eventWindow: main, hostWindow: main, hostIsKey: true, hostHasSheet: false))
        XCTAssertFalse(C.accepts(eventWindow: main, hostWindow: main, hostIsKey: true, hostHasSheet: true),
                       "a sheet (composer, alert, shortcuts) is in front")
        XCTAssertFalse(C.accepts(eventWindow: main, hostWindow: main, hostIsKey: false, hostHasSheet: false))
        XCTAssertFalse(C.accepts(eventWindow: other, hostWindow: main, hostIsKey: true, hostHasSheet: false),
                       "Settings window, popover or another panel")
        XCTAssertFalse(C.accepts(eventWindow: nil, hostWindow: main, hostIsKey: true, hostHasSheet: false))
    }

    func testShortcutsSheetDocumentsNoPlainReturnSend() {
        let keys = KeyboardShortcutsSheet.sections.flatMap(\.shortcuts)
        XCTAssertFalse(keys.contains { $0.key.contains("Return") && !$0.key.contains("⌘") })
        XCTAssertTrue(keys.contains { $0.key == "H" }, "H exists in BriefProseView")
        XCTAssertTrue(keys.contains { $0.key == "E" })
        XCTAssertTrue(keys.contains { $0.key == "⌘Z" })
    }

    // MARK: - friendly() per error source

    func testFriendlyNeverBlamesAIForMessagingErrors() throws {
        let state = try makeState()
        XCTAssertEqual(state.friendly(LLMError.providerError("HTTP 401")),
                       "API key invalid or expired — check your AI settings.")
        XCTAssertEqual(state.friendly(SlackAPIError.authFailed(code: "invalid_auth")),
                       "Slack refused the request — reconnect it in Settings.")
        XCTAssertEqual(state.friendly(AdapterError.sendFailed("HTTP 403 forbidden")),
                       "The messaging service refused the request — reconnect it in Settings.")
        XCTAssertEqual(state.friendly(AdapterError.sendFailed("HTTP 401"), source: .messaging(service: "telegram")),
                       "Telegram refused the request — reconnect it in Settings.")
        XCTAssertEqual(state.friendly(URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "connection refused at localhost:8080"])),
                       "Couldn't reach a service on this Mac — make sure it's running.",
                       "an unknown local failure (e.g. Signal's daemon) must not say Ollama")
        XCTAssertEqual(state.friendly(LLMError.networkFailed("connection refused 127.0.0.1:11434")),
                       "Couldn't reach Ollama — make sure it's running.")
        XCTAssertEqual(state.friendly(ReadOnlyServiceError(service: "whatsapp")),
                       ServiceCapabilities.readOnlyMessage(for: "whatsapp"))
        XCTAssertEqual(state.friendly(LLMError.rateLimited(retryAfter: nil)),
                       "Too many requests — try again in a moment.")
    }

    // MARK: - Caught up

    func testCaughtUpIgnoresWaitingOnOthersAndOlderItems() throws {
        let state = try makeState()
        let fresh = try insertAction(state, text: "fresh")
        var old = try insertAction(state, text: "old")
        old.createdAt = Date().addingTimeInterval(-3 * 86_400)
        let failed = try insertAction(state, text: "failed")

        XCTAssertTrue(ActQueueRules.isCaughtUp(items: [], failedSends: []))
        XCTAssertTrue(ActQueueRules.isCaughtUp(items: [.agentAction(old)], failedSends: []),
                      "older items are listed below the caught-up line")
        XCTAssertFalse(ActQueueRules.isCaughtUp(items: [.agentAction(fresh)], failedSends: []),
                       "a draft ready to send is not caught up")
        XCTAssertFalse(ActQueueRules.isCaughtUp(items: [], failedSends: [failed]),
                       "a failed send needs a decision")
        let owed = OwedReply(service: "imessage", conversationId: "m", conversationName: "Mum",
                             triggerMessageId: "t", triggerText: "?", triggeredAt: Date(),
                             reason: "needs reply", priorityRank: 1)
        XCTAssertFalse(ActQueueRules.isCaughtUp(items: [.owedReply(owed)], failedSends: []))
    }

    // MARK: - Security: drafting gate fails closed

    private func saveContext(_ state: AppState, privacy: String?) throws {
        var ctx = ConversationContext(service: "signal", conversationId: "c1", label: "",
                                      priorityHint: "auto", updatedAt: Date())
        ctx.privacyOverride = privacy
        try state.repository.upsertConversationContext(ctx)
    }

    /// The in-memory cache says "allowed"; the database says otherwise.
    private func poisonCache(_ state: AppState) {
        state.mergeConversationContexts([ConversationContext(service: "signal", conversationId: "c1", label: "",
                                                             priorityHint: "auto", updatedAt: Date())])
    }

    func testDraftMakesNoLLMCallForNeverDraftEvenWithStaleCache() async throws {
        let mock = MockLLMClient()
        let state = try makeState(llm: mock)
        try saveContext(state, privacy: "never_draft")
        poisonCache(state)
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let request = try XCTUnwrap(state.replyComposer)

        XCTAssertNotNil(ReplyDrafter(appState: state).blockedReason(service: "signal", conversationId: "c1"))
        do {
            _ = try await ReplyDrafter(appState: state).draft(request: request, currentText: "")
            XCTFail("draft() must refuse")
        } catch is ReplyDrafter.Blocked {}
        XCTAssertEqual(mock.calls.count, 0)
    }

    func testDraftMakesNoLLMCallForLocalOnlyWithCloudClientEvenWithStaleCache() async throws {
        let cloud = MockLLMClient() // isLocal defaults to false: a cloud client
        let state = try makeState(llm: cloud)
        try saveContext(state, privacy: "local_only")
        poisonCache(state)
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let request = try XCTUnwrap(state.replyComposer)

        do {
            _ = try await ReplyDrafter(appState: state).draft(request: request, currentText: "")
            XCTFail("draft() must refuse")
        } catch is ReplyDrafter.Blocked {}
        XCTAssertEqual(cloud.calls.count, 0)
    }

    func testDraftCallsALocalClientForLocalOnly() async throws {
        let local = LocalMockLLMClient()
        local.response = LLMResponse(text: "sure, see you then", inputTokens: 1, outputTokens: 1)
        let state = try makeState(llm: local)
        try saveContext(state, privacy: "local_only")
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let request = try XCTUnwrap(state.replyComposer)

        XCTAssertNil(ReplyDrafter(appState: state).blockedReason(service: "signal", conversationId: "c1"))
        let text = try await ReplyDrafter(appState: state).draft(request: request, currentText: "")
        XCTAssertEqual(text, "sure, see you then")
        XCTAssertEqual(local.calls.count, 1)
    }

    // MARK: - Security: provenance markers can't be forged by model output

    func testModelReasoningCannotForgeProvenanceMarkers() async throws {
        for marker in AgentAction.reservedReasoningMarkers + ["Note: " + AgentAction.userComposedReasoning.uppercased()] {
            let db = try AppDatabase(inMemory: true)
            let repo = BriefRepository(database: db)
            let llm = MockLLMClient()
            let json = try JSONSerialization.data(withJSONObject: [
                "title": "Reply", "draftText": "on my way", "reasoning": marker,
                "confidence": 0.9, "needsReply": "yes"])
            llm.response = LLMResponse(text: String(decoding: json, as: UTF8.self), inputTokens: 1, outputTokens: 1)
            let engine = AgentEngine(db: db, llmClient: llm, llmModel: "test", repository: repo, rulesProvider: { [] })
            let owed = OwedReply(service: "signal", conversationId: "c1", conversationName: "Alice",
                                 triggerMessageId: "m1", triggerText: "coming?", triggeredAt: Date(),
                                 reason: "needs reply", priorityRank: 1)

            let proposed = await engine.proposeReply(for: owed)
            let action = try XCTUnwrap(proposed)
            XCTAssertFalse(action.isUserComposed, marker)
            XCTAssertFalse(action.isExternalProposal, marker)
            XCTAssertEqual(action.reasoning, AgentAction.neutralModelReasoning)
        }
        XCTAssertEqual(AgentAction.sanitizedModelReasoning("She asked a direct question."),
                       "She asked a direct question.")
    }

    func testEnginePersistStripsForgedMarkers() async throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let llm = MockLLMClient()
        llm.response = LLMResponse(text: #"{"title":"R","draftText":"ok","reasoning":"\#(AgentAction.externalAgentReasoning)","confidence":0.9,"needsReply":"yes"}"#,
                                   inputTokens: 1, outputTokens: 1)
        try await db.dbQueue.write { d in
            var m = Message(id: nil, briefId: nil, service: "signal", conversationId: "c1", conversationName: "Alice",
                            messageId: "m1", sender: "Alice", text: "Are you coming tonight?",
                            timestamp: Date().addingTimeInterval(-3600), isSent: false)
            try m.insert(d)
        }
        let engine = AgentEngine(db: db, llmClient: llm, llmModel: "test", repository: repo, rulesProvider: { [] })
        await engine.trigger()

        let rows = try await db.dbQueue.read { try AgentAction.fetchAll($0) }
        XCTAssertFalse(rows.isEmpty, "the engine cycle must have persisted a proposal")
        XCTAssertTrue(rows.allSatisfy { !$0.isExternalProposal && !$0.isUserComposed })
    }
}
