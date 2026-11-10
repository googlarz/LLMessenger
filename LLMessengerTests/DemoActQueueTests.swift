// LLMessengerTests/DemoActQueueTests.swift
//
// The demo's Act screen. The seeded world must come back through the same read
// paths real data uses (OwedReplyDeriver, fetchPendingAgentActions, commitments,
// tasks) and land in the right Act sections; no sample draft may ever reach a
// real adapter; and wiping the demo must leave nothing of it behind.

import XCTest
import GRDB
@testable import LLMessenger

private final class RecordingAdapter: MessengerAdapter, @unchecked Sendable {
    func listContacts() async -> [Contact] { [] }
    let serviceID: String
    var healthStatus: AdapterHealthResult.Status = .ok
    private let lock = NSLock()
    private var _sent: [(conversationID: String, text: String)] = []
    private var _stopped = false
    var sent: [(conversationID: String, text: String)] { lock.lock(); defer { lock.unlock() }; return _sent }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
    init(_ serviceID: String) { self.serviceID = serviceID }
    func start() async throws {}
    func stop() { lock.lock(); _stopped = true; lock.unlock() }
    func fetch(config: FetchConfig) async throws -> AdapterFetchResult { AdapterFetchResult(conversations: []) }
    func send(conversationID: String, text: String) async throws {
        lock.withLock { _sent.append((conversationID, text)) }
    }
    func healthCheck() async -> AdapterHealthResult { AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil) }
}

@MainActor
final class DemoActQueueTests: XCTestCase {

    private var savedWindow: TimeInterval = 5

    override func setUp() async throws {
        savedWindow = AppState.sampleSendWindow
    }

    override func tearDown() async throws {
        AppState.sampleSendWindow = savedWindow
        UserDefaults.standard.removeObject(forKey: DemoSeeder.demoFlagKey)
    }

    // MARK: - Fixtures

    private func seededDB() throws -> AppDatabase {
        let db = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: db)
        return db
    }

    private func projection(_ db: AppDatabase) throws -> AttentionProjection {
        let repo = BriefRepository(database: db)
        let contexts = try repo.fetchAllConversationContexts()
        let owed = try OwedReplyDeriver().derive(db: db, contexts: contexts)
        return AttentionProjection.build(
            briefs: try repo.fetchAllBriefs(),
            cardsByBriefID: [:],
            handledCardKeys: [],
            actions: try repo.fetchPendingAgentActions(),
            owedReplies: owed,
            commitments: try repo.fetchOpenCommitments(),
            tasks: try repo.fetchPendingTasks(),
            contextsByKey: Dictionary(contexts.map { ("\($0.service)|\($0.conversationId)", $0) },
                                      uniquingKeysWith: { a, _ in a }))
    }

    private func makeState(_ db: AppDatabase) -> AppState {
        let defaults = UserDefaults(suiteName: "DemoActQueueTests-\(UUID().uuidString)")!
        return AppState(database: db, llmClient: UnconfiguredLLMClient(), llmModel: "demo",
                        isLLMConfigured: false, basePrompt: "", defaults: defaults)
    }

    private func sampleAction(_ state: AppState, conversation: String) throws -> AgentAction {
        try XCTUnwrap(try state.repository.fetchPendingAgentActions().first { $0.conversationId == conversation })
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: - What the Act screen shows

    func testSeededWorldLandsInTheExpectedActSections() throws {
        let db = try seededDB()
        let p = try projection(db)
        let sections = Dictionary(grouping: p.actItems) { ActQueueRules.section(for: $0) }

        let decision = sections[.decision] ?? []
        XCTAssertEqual(decision.count, 3, "Anna's question, the WhatsApp question and one Maybe draft")
        guard case .owedReply(let anna) = try XCTUnwrap(decision.first) else {
            return XCTFail("An unanswered question with no draft is ranked first")
        }
        XCTAssertEqual(anna.service, "signal")
        XCTAssertEqual(anna.conversationId, "demo-meridian")
        XCTAssertTrue(anna.triggerText.contains("cap table"))
        let owedWhatsApp = decision.compactMap { item -> OwedReply? in
            if case .owedReply(let o) = item, o.service == "whatsapp" { return o }
            return nil
        }
        XCTAssertEqual(owedWhatsApp.first?.conversationId, "demo-football",
                       "A read-only service shows up as a question to answer, never as a sendable draft")
        XCTAssertFalse(p.actItems.contains { if case .agentAction(let a) = $0 { return a.service == "whatsapp" }; return false })
        guard case .agentAction(let maybe) = decision.last else { return XCTFail("The Maybe draft follows") }
        XCTAssertTrue(maybe.isMaybe)
        XCTAssertEqual(maybe.service, "slack")

        let ready = sections[.ready] ?? []
        XCTAssertEqual(Set(ready.map(\.service)), ["imessage", "signal"], "Two drafts on different services")
        XCTAssertEqual(ready.count, 2)
        for item in ready {
            guard case .agentAction(let a) = item else { return XCTFail("Ready rows are drafts") }
            XCTAssertFalse(a.isMaybe)
            XCTAssertNotNil(a.replyPayload?.draftText)
        }

        let older = sections[.older] ?? []
        XCTAssertEqual(older.count, 1)
        XCTAssertEqual(older.first?.conversationId, "demo-mum")

        XCTAssertEqual(p.commitments.count, 1)
        XCTAssertEqual(p.commitments.first?.directionEnum, .theyOwe, "Waiting on someone else")
        XCTAssertEqual(p.tasks.count, 1, "The cap-table task is still there")
        XCTAssertFalse(p.actItems.contains { $0.conversationId == "demo-sailing" },
                       "The noisy group needs nothing")
        XCTAssertEqual(p.actItems.count, 6)
        // One obligation, not two: a drafted conversation does not also show as owed.
        XCTAssertEqual(Set(p.actItems.map { "\($0.service)|\($0.conversationId)" }).count, 6)
    }

    func testActAndDigestsTellTheSameStory() throws {
        let db = try seededDB()
        let p = try projection(db)
        let digestConversations = Set(try BriefRepository(database: db).fetchAllBriefs()
            .compactMap { BriefJSON.decodedCached(for: $0) }
            .flatMap(\.cards).map(\.conversationId))
        for id in ["demo-meridian", "demo-dad", "demo-launch-room"] {
            XCTAssertTrue(digestConversations.contains(id))
            XCTAssertTrue(p.actItems.contains { $0.conversationId == id } || p.commitments.contains { $0.conversationId == id },
                          "\(id) appears in Act as well as in the digest")
        }
    }

    // MARK: - Nothing reaches a real adapter

    func testNoSampleDraftIsDelegatableOrLowRisk() throws {
        let db = try seededDB()
        let actions = try BriefRepository(database: db).fetchPendingAgentActions()
        XCTAssertEqual(actions.count, 3)
        let permissive = ConversationContext(service: "x", conversationId: "x", label: "", priorityHint: "auto",
                                             updatedAt: Date())
        for action in actions {
            XCTAssertTrue(action.isSample)
            XCTAssertNotEqual(action.riskEnum, .low, "batchApproveLowRisk only stages low-risk rows")
            let decision = AgentDelegation.decide(action: action, context: permissive,
                                                  isKnownRecipient: true, clientIsLocal: true)
            XCTAssertFalse(decision.autoSend, "\(action.conversationName): \(decision.reason)")
        }
    }

    func testSendingASampleDraftNeverCallsAnAdapter() async throws {
        AppState.sampleSendWindow = 0.1
        let db = try seededDB()
        let state = makeState(db)
        // Even with live-looking adapters present, the sample path must not use them.
        let adapters = ["imessage", "signal", "slack"].map(RecordingAdapter.init)
        for a in adapters { state.adapters[a.serviceID] = a }

        let dad = try sampleAction(state, conversation: "demo-dad")
        state.stageSend(dad)
        XCTAssertEqual(try state.repository.fetchAgentAction(id: dad.id!)?.statusEnum, .scheduled,
                       "It counts down like a real send")

        await waitUntil { (try? state.repository.fetchAgentAction(id: dad.id!))?.statusEnum == .done }
        XCTAssertEqual(try state.repository.fetchAgentAction(id: dad.id!)?.statusEnum, .done)
        await waitUntil { state.userReceipt != nil }
        XCTAssertTrue(state.userReceipt?.text.contains("sample") ?? false, state.userReceipt?.text ?? "no toast")
        XCTAssertFalse(state.userReceipt?.text.hasPrefix("Sent to") ?? true)
        XCTAssertTrue(adapters.allSatisfy { $0.sent.isEmpty }, "No adapter was asked to send")
    }

    func testUndoCancelsASampleSend() async throws {
        AppState.sampleSendWindow = 0.3
        let state = makeState(try seededDB())
        let dad = try sampleAction(state, conversation: "demo-dad")
        state.stageSend(dad)
        let staged = try XCTUnwrap(try state.repository.fetchAgentAction(id: dad.id!))
        XCTAssertEqual(staged.statusEnum, .scheduled)
        state.undoStagedSend(staged)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(try state.repository.fetchAgentAction(id: dad.id!)?.statusEnum, .pending,
                       "Undo returns the draft to the queue and the timer never completes it")
    }

    func testComposerReplyToASampleConversationIsAlsoSampleOnly() async throws {
        AppState.sampleSendWindow = 0.1
        let state = makeState(try seededDB())
        let signal = RecordingAdapter("signal")
        state.adapters["signal"] = signal
        let request = ReplyComposerRequest(service: "signal", conversationId: "demo-meridian",
                                           conversationName: "Meridian — Series B", isGroup: false,
                                           initialText: "", sourceActionID: nil, commitmentId: nil)
        guard case .staged(let id) = state.sendFromComposer(request, text: "On it — Wednesday.") else {
            return XCTFail("The composer stages the reply")
        }
        await waitUntil { (try? state.repository.fetchAgentAction(id: id))?.statusEnum == .done }
        XCTAssertEqual(try state.repository.fetchAgentAction(id: id)?.statusEnum, .done)
        XCTAssertTrue(signal.sent.isEmpty)
    }

    func testBatchApproveAndDelegationDoNothingForSampleDrafts() async throws {
        let state = makeState(try seededDB())
        let adapters = ["imessage", "signal", "slack"].map(RecordingAdapter.init)
        for a in adapters { state.adapters[a.serviceID] = a }
        state.reloadAgentActions()
        await waitUntil { state.agentActions.count == 3 }

        state.batchApproveLowRisk()
        state.evaluateDelegation()
        try await Task.sleep(nanoseconds: 300_000_000)

        let rows = try state.repository.fetchPendingAgentActions()
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.statusEnum == .pending }, "Nothing was staged or armed")
        XCTAssertTrue(adapters.allSatisfy { $0.sent.isEmpty })
    }

    func testDemoModeHoldsNoAdaptersSoEvenTheRealTimerPathCannotSend() async throws {
        let state = makeState(try seededDB())
        let imessage = RecordingAdapter("imessage")
        state.adapters["imessage"] = imessage

        state.detachAdaptersForDemo()
        XCTAssertTrue(state.adapters.isEmpty)
        XCTAssertTrue(imessage.stopped)

        // The real fire path, driven directly on a sample row.
        let dad = try sampleAction(state, conversation: "demo-dad")
        XCTAssertTrue(try state.repository.armAgentActionForAutoSend(
            id: dad.id!, scheduledAt: Date().addingTimeInterval(60), kind: .manual, undoWindow: 5))
        await state.fireManualApprovedSend(actionID: dad.id!)
        await waitUntil { (try? state.repository.fetchAgentAction(id: dad.id!))?.statusEnum == .pending }
        XCTAssertEqual(try state.repository.fetchAgentAction(id: dad.id!)?.statusEnum, .pending,
                       "\"Not connected\": the row goes back to the queue")
        XCTAssertTrue(imessage.sent.isEmpty)
    }

    func testStartDemoModeLandsOnActAndDropsAdapters() async throws {
        let state = makeState(try AppDatabase(inMemory: true))
        let adapter = RecordingAdapter("imessage")
        state.adapters["imessage"] = adapter
        state.startDemoMode()
        await waitUntil { state.requestedSection == .act }
        XCTAssertEqual(state.requestedSection, .act)
        XCTAssertTrue(state.adapters.isEmpty)
        await waitUntil { state.attentionProjection.actItems.count == 6 }
        XCTAssertEqual(state.attentionProjection.actItems.count, 6)
    }

    // MARK: - Real contacts whose id looks like a sample id

    private let lookalike = "demo-team@example.com"

    private func insertLookalikeAction(_ state: AppState) throws -> AgentAction {
        let action = AgentAction.userComposed(service: "imessage", conversationId: lookalike,
                                              conversationName: "Demo Team", text: "see you then", commitmentId: nil)
        let id = try XCTUnwrap(state.repository.insertAgentAction(action))
        return try XCTUnwrap(state.repository.fetchAgentAction(id: id))
    }

    func testSampleMeansDemoActiveAndAnExactSeededConversation() throws {
        let state = makeState(try seededDB())
        let dad = try sampleAction(state, conversation: "demo-dad")
        XCTAssertTrue(dad.isSample, "Seeded conversation while demo mode is active")
        let real = try insertLookalikeAction(state)
        XCTAssertFalse(real.isSample, "A look-alike id is not a seeded conversation")
        var otherService = dad
        otherService.service = "telegram"
        XCTAssertFalse(otherService.isSample, "The pair must match exactly, service included")

        UserDefaults.standard.removeObject(forKey: DemoSeeder.demoFlagKey)
        XCTAssertFalse(dad.isSample, "Outside demo mode nothing is sample, whatever its id")
    }

    func testRealActionWithDemoLikeIdTakesTheNormalSendPath() async throws {
        AppState.sampleSendWindow = 0.1
        let state = makeState(try seededDB())
        let imessage = RecordingAdapter("imessage")
        state.adapters["imessage"] = imessage
        let real = try insertLookalikeAction(state)
        state.stageSend(real)
        // A diverted (fake) send would be finished after 0.1s. The real manual
        // path keeps its five-second undo window.
        try await Task.sleep(nanoseconds: 700_000_000)
        let row = try XCTUnwrap(try state.repository.fetchAgentAction(id: real.id!))
        XCTAssertEqual(row.statusEnum, .scheduled, "Still counting down in the real undo window")
        XCTAssertEqual(row.scheduledKind, AgentActionScheduleKind.manual.rawValue)
        XCTAssertEqual(row.scheduledWindow, AgentAction.manualApproveUndoWindow,
                       "stageManualApprove's window, not the sample window")
        state.undoStagedSend(row)
    }

    func testRealActionWithDemoLikeIdTakesTheNormalSendPathOutsideDemoMode() async throws {
        AppState.sampleSendWindow = 0.1
        let state = makeState(try AppDatabase(inMemory: true))
        XCTAssertFalse(DemoSeeder.isActive)
        let real = try insertLookalikeAction(state)
        state.stageSend(real)
        try await Task.sleep(nanoseconds: 700_000_000)
        let row = try XCTUnwrap(try state.repository.fetchAgentAction(id: real.id!))
        XCTAssertEqual(row.statusEnum, .scheduled)
        XCTAssertEqual(row.scheduledWindow, AgentAction.manualApproveUndoWindow)
        state.undoStagedSend(row)
    }

    // MARK: - Wipe

    func testWipeRemovesEverySeededRowAndNoRealRow() throws {
        let db = try seededDB()
        let repo = BriefRepository(database: db)
        // A reply the user composed inside the sample world, and a dismissed sample owed reply.
        _ = try repo.insertAgentAction(AgentAction.userComposed(
            service: "signal", conversationId: "demo-meridian", conversationName: "Anna", text: "On it",
            commitmentId: nil))
        let seededOwed = try OwedReplyDeriver().derive(db: db, contexts: []).first { $0.conversationId == "demo-meridian" }
        let seededOwedID = try XCTUnwrap(seededOwed).id
        OwedReplyStore.dismiss(seededOwedID)
        // A real contact whose id merely looks like a sample id.
        let realOwedID = "imessage|\(lookalike)|real-m1"
        OwedReplyStore.dismiss(realOwedID)
        defer { OwedReplyStore.undismiss(seededOwedID); OwedReplyStore.undismiss(realOwedID) }
        try db.dbQueue.write { d in
            var m = Message(id: nil, briefId: nil, service: "imessage", conversationId: lookalike,
                            conversationName: "Demo Team", messageId: "real-m1", sender: "Demo Team",
                            text: "Are you in?", timestamp: Date(), isSent: false)
            try m.insert(d)
        }
        _ = try repo.insertAgentAction(AgentAction.userComposed(
            service: "imessage", conversationId: lookalike, conversationName: "Demo Team", text: "hi",
            commitmentId: nil))
        _ = try repo.insertCommitment(Commitment(
            id: nil, direction: CommitmentDirection.iOwe.rawValue, service: "imessage", conversationId: lookalike,
            conversationName: "Demo Team", what: "x", dueAt: nil, evidenceMessageId: nil,
            status: CommitmentStatus.open.rawValue, createdAt: Date()))

        try DemoSeeder.wipe(from: db)

        func count(_ sql: String) throws -> Int {
            try db.dbQueue.read { try Int.fetchOne($0, sql: sql) ?? -1 }
        }
        for t in ["briefs", "briefCards", "briefCardSources", "tasks", "conversationContexts", "serviceConfig"] {
            XCTAssertEqual(try count("SELECT COUNT(*) FROM \(t)"), 0, t)
        }
        XCTAssertEqual(try count("SELECT COUNT(*) FROM messages WHERE conversationId <> '\(lookalike)'"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM agentActions WHERE conversationId <> '\(lookalike)'"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM commitments WHERE conversationId <> '\(lookalike)'"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM messages WHERE conversationId = '\(lookalike)'"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM agentActions WHERE conversationId = '\(lookalike)'"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM commitments WHERE conversationId = '\(lookalike)'"), 1)
        XCTAssertFalse(OwedReplyStore.dismissedIDs().contains(seededOwedID))
        XCTAssertTrue(OwedReplyStore.dismissedIDs().contains(realOwedID), "The real dismissal survives")
        XCTAssertFalse(DemoSeeder.isActive)
    }
}
