// LLMessengerTests/BackendWorkflowE2ETests.swift
// End-to-end tests for every backend workflow seam.
// Group 1: PollEngine.onPollSucceeded → BriefEngine.processNewMessages callback chain.
import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class BackendWorkflowE2ETests: XCTestCase {

    // MARK: - Shared helpers

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func signalConfig(enabled: Bool = true) -> ServiceConfig {
        ServiceConfig(service: "signal", enabled: enabled,
                      pollIntervalMinutes: 30, fetchMode: "time",
                      fetchLimit: 50, privacyMode: "eager")
    }

    private func telegramConfig(enabled: Bool = true) -> ServiceConfig {
        ServiceConfig(service: "telegram", enabled: enabled,
                      pollIntervalMinutes: 30, fetchMode: "time",
                      fetchLimit: 50, privacyMode: "eager")
    }

    private func makeEngine(db: AppDatabase) -> PollEngine { PollEngine(database: db) }

    private func makeBriefEngine(db: AppDatabase, mock: LLMClient) -> BriefEngine {
        BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")
    }

    /// Wires PollEngine → BriefEngine and returns both.
    private func makeWiredPipeline(db: AppDatabase, mock: LLMClient)
        -> (engine: PollEngine, brief: BriefEngine) {
        let engine = makeEngine(db: db)
        let briefEngine = makeBriefEngine(db: db, mock: mock)
        engine.onPollSucceeded = { [briefEngine] in
            _ = try? await briefEngine.processNewMessages()
        }
        return (engine, briefEngine)
    }

    // MARK: - Group 1: Primary Pipeline Seam

    // 1.1 — Full happy path: poll stores message → callback fires → brief created.
    func testPollTriggersFullBriefPipelineViaCallback() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        let (engine, _) = makeWiredPipeline(db: db, mock: mock)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")
        engine.register(adapter: adapter, config: signalConfig())

        await engine.pollAll()

        let msgCount = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(msgCount, 1, "pollAll must store the message")

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 1, "onPollSucceeded must trigger brief creation")

        let brief = try await db.dbQueue.read { d in try Brief.fetchAll(d).first }
        XCTAssertNotNil(brief, "Brief must exist")
        XCTAssertEqual(brief?.status, "ready", "Brief status must be ready")

        let msg = try await db.dbQueue.read { d in try Message.fetchAll(d).first }
        XCTAssertNotNil(msg?.briefId, "Message must be attached to the brief")
    }

    // 1.2 — No new messages → onPollSucceeded must NOT fire → no brief created.
    func testNoBriefWhenPollHasNoNewMessages() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()

        let (engine, _) = makeWiredPipeline(db: db, mock: mock)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        // No messages added — empty conversations
        engine.register(adapter: adapter, config: signalConfig())

        await engine.pollAll()

        let msgCount = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(msgCount, 0, "No messages should be stored when adapter returns nothing")

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 0, "No brief should be created when there are no new messages")
    }

    // 1.3 — Same message on cycle 2 → INSERT OR IGNORE dedup → onPollSucceeded NOT fired → no second brief.
    func testSecondPollWithSameMessageDoesNotCreateSecondBrief() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        let (engine, _) = makeWiredPipeline(db: db, mock: mock)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")
        engine.register(adapter: adapter, config: signalConfig())

        // Cycle 1 — message stored, brief created
        await engine.pollAll()
        let briefCountAfterCycle1 = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCountAfterCycle1, 1, "Precondition: cycle 1 must create one brief")

        let briefId = try await db.dbQueue.read { d in try Brief.fetchAll(d).first?.id }

        // Cycle 2 — same adapter, same message; dedup must prevent onPollSucceeded firing
        await engine.pollAll()

        let briefCountAfterCycle2 = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCountAfterCycle2, 1, "Second poll with same message must not create a second brief")

        let msgCount = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(msgCount, 1, "Message count must remain 1 after dedup")

        let msg = try await db.dbQueue.read { d in try Message.fetchAll(d).first }
        XCTAssertEqual(msg?.briefId, briefId, "Message briefId must remain attached to original brief")
    }

    // 1.4 — LLM failure on cycle 1 leaves messages unattached; cycle 2 succeeds and attaches all.
    func testMessagesFromFailedBriefCycleAreRetriedInNextCycle() async throws {
        let db = try makeDB()

        // Cycle 1: mock fails
        let failingMock = DynamicMockLLMClient()
        failingMock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"], fail: true)
        let engine1 = makeEngine(db: db)
        let briefEngine1 = makeBriefEngine(db: db, mock: failingMock)
        engine1.onPollSucceeded = { [briefEngine1] in
            _ = try? await briefEngine1.processNewMessages()
        }
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")
        engine1.register(adapter: adapter, config: signalConfig())

        await engine1.pollAll()

        let briefCountAfterCycle1 = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCountAfterCycle1, 0, "Brief must NOT be created when LLM fails")

        let m1 = try await db.dbQueue.read { d in
            try Message.filter(Column("messageId") == "m1").fetchOne(d)
        }
        XCTAssertNotNil(m1, "m1 must be stored even when LLM fails")
        XCTAssertNil(m1?.briefId, "m1 must remain unattached after failed cycle")

        // Cycle 2: add m2, mock succeeds covering both m1 and m2
        let succeedingMock = DynamicMockLLMClient()
        succeedingMock.specs["signal"] = .init(convId: "c1", messageIds: ["m1", "m2"])
        let engine2 = makeEngine(db: db)
        let briefEngine2 = makeBriefEngine(db: db, mock: succeedingMock)
        engine2.onPollSucceeded = { [briefEngine2] in
            _ = try? await briefEngine2.processNewMessages()
        }
        adapter.addMessage(convId: "c1", msgId: "m2")
        engine2.register(adapter: adapter, config: signalConfig())

        await engine2.pollAll()

        let briefCountAfterCycle2 = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCountAfterCycle2, 1, "One brief must be created on cycle 2")

        let msgCount = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(msgCount, 2, "Both messages must be stored")

        let brief = try await db.dbQueue.read { d in try Brief.fetchAll(d).first }
        let briefRowId = try XCTUnwrap(brief?.id)

        let m1After = try await db.dbQueue.read { d in
            try Message.filter(Column("messageId") == "m1").fetchOne(d)
        }
        let m2After = try await db.dbQueue.read { d in
            try Message.filter(Column("messageId") == "m2").fetchOne(d)
        }
        XCTAssertEqual(m1After?.briefId, briefRowId, "m1 must be attached to the brief on cycle 2")
        XCTAssertEqual(m2After?.briefId, briefRowId, "m2 must be attached to the brief on cycle 2")
    }

    // 1.5 — Two services polled → single brief covering both.
    func testMultiServicePollProducesSingleBriefCoveringBothServices() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["sig-m1"])
        mock.specs["telegram"] = .init(convId: "c2", messageIds: ["tg-m1"])

        let (engine, _) = makeWiredPipeline(db: db, mock: mock)

        let signalAdapter = FakeMessengerAdapter(serviceID: "signal")
        signalAdapter.addMessage(convId: "c1", msgId: "sig-m1")
        engine.register(adapter: signalAdapter, config: signalConfig())

        let telegramAdapter = FakeMessengerAdapter(serviceID: "telegram")
        telegramAdapter.addMessage(convId: "c2", msgId: "tg-m1")
        engine.register(adapter: telegramAdapter, config: telegramConfig())

        await engine.pollAll()

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 1, "Multi-service poll must produce exactly one brief")

        let briefOptional = try await db.dbQueue.read { d in try Brief.fetchAll(d).first }
        let brief = try XCTUnwrap(briefOptional)
        let services = try JSONDecoder().decode([String].self, from: Data(brief.services.utf8))
        XCTAssertTrue(services.contains("signal"), "Brief services must include signal")
        XCTAssertTrue(services.contains("telegram"), "Brief services must include telegram")

        let msgCount = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(msgCount, 2, "Both service messages must be stored")

        let msgs = try await db.dbQueue.read { d in try Message.fetchAll(d) }
        XCTAssertTrue(msgs.allSatisfy { $0.briefId == brief.id }, "All messages must be attached to the brief")
    }

    // 1.6 — Signal adapter fails, telegram succeeds → brief covers only telegram; signal health = error.
    func testPartialAdapterFailureProducesBriefForSuccessfulServiceOnly() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["telegram"] = .init(convId: "c2", messageIds: ["tg-m1"])

        let (engine, _) = makeWiredPipeline(db: db, mock: mock)

        let signalAdapter = FakeMessengerAdapter(serviceID: "signal")
        signalAdapter.shouldFailFetch = true
        engine.register(adapter: signalAdapter, config: signalConfig())

        let telegramAdapter = FakeMessengerAdapter(serviceID: "telegram")
        telegramAdapter.addMessage(convId: "c2", msgId: "tg-m1")
        engine.register(adapter: telegramAdapter, config: telegramConfig())

        await engine.pollAll()

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 1, "Brief must be created for the successful telegram service")

        let msgCount = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(msgCount, 1, "Only telegram message must be stored (signal fetch failed)")

        let health = try await db.dbQueue.read { d in
            try ServiceHealth.fetchOne(d, key: "signal")
        }
        XCTAssertEqual(health?.status, "error", "Signal service health must be error after fetch failure")
    }

    // MARK: - Group 2: Memory Compression

    // 2.1 — Second brief cycle compresses the first brief before generating the new one.
    func testSecondBriefCycleCompressesPreviousBriefFirst() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        // Cycle 1
        let briefEngine1 = makeBriefEngine(db: db, mock: mock)
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m1", sender: "Alice", text: "Hi",
                            timestamp: Date().addingTimeInterval(-60), isSent: false)
            try m.insert(d)
        }
        _ = try await briefEngine1.processNewMessages()

        // Verify B1 has no episodicSummary yet
        let b1 = try await db.dbQueue.read { d in try Brief.fetchAll(d).first }
        XCTAssertNil(b1?.episodicSummary, "Precondition: B1 must not be compressed yet")

        // Cycle 2: update mock for m2, create new engine instance
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])
        let briefEngine2 = makeBriefEngine(db: db, mock: mock)
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m2", sender: "Alice", text: "More",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }
        _ = try await briefEngine2.processNewMessages()

        // B1 must now have episodicSummary set by compressor
        let b1After = try await db.dbQueue.read { d in
            try Brief.order(Column("createdAt").asc).fetchAll(d).first
        }
        XCTAssertNotNil(b1After?.episodicSummary,
            "First brief must be compressed before second brief cycle — MemoryCompressor runs on oldest uncompressed brief")
        XCTAssertFalse(b1After?.episodicSummary?.isEmpty ?? true)

        // B2 must exist
        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 2, "Two briefs must exist after two successful cycles")
    }

    // 2.2 — A brief that already has an episodicSummary is not re-compressed.
    func testAlreadyCompressedBriefIsNotReCompressed() async throws {
        let db = try makeDB()

        // Insert B1 directly with episodicSummary already set
        let briefId1 = try await db.dbQueue.write { d -> Int64 in
            var b = Brief(createdAt: Date().addingTimeInterval(-120), status: "ready",
                          services: #"["signal"]"#, openingSummary: nil,
                          notificationText: "x", episodicSummary: "Already compressed.")
            try b.insert(d)
            var m = Message(briefId: b.id!, service: "signal", conversationId: "c1",
                            messageId: "m1", sender: "Alice", text: "Hi",
                            timestamp: Date().addingTimeInterval(-120), isSent: false)
            try m.insert(d)
            return b.id!
        }

        // Insert m2 for cycle 2
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m2", sender: "Alice", text: "More",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])
        let briefEngine = makeBriefEngine(db: db, mock: mock)
        _ = try await briefEngine.processNewMessages()

        // B1's episodicSummary must remain unchanged
        let b1 = try await db.dbQueue.read { d in try Brief.fetchOne(d, key: briefId1) }
        XCTAssertEqual(b1?.episodicSummary, "Already compressed.",
            "Compressor must skip briefs that already have episodicSummary — must be idempotent")

        let count = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(count, 2)
    }

    // 2.3 — The episodic summary from cycle 1 appears in cycle 2's brief prompt.
    func testEpisodicSummaryAppearsInNextBriefPrompt() async throws {
        let db = try makeDB()

        // Cycle 1 with DynamicMockLLMClient
        let mock1 = DynamicMockLLMClient()
        mock1.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m1", sender: "Alice", text: "Hi",
                            timestamp: Date().addingTimeInterval(-120), isSent: false)
            try m.insert(d)
        }
        _ = try await makeBriefEngine(db: db, mock: mock1).processNewMessages()

        // Cycle 2 with CapturingMockLLMClient
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m2", sender: "Alice", text: "More",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }
        let capturingMock = CapturingMockLLMClient()
        capturingMock.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])
        _ = try await makeBriefEngine(db: db, mock: capturingMock).processNewMessages()

        // Find the brief generation call (not the compressor call)
        let briefCall = capturingMock.capturedCalls.first(where: { !$0.systemPrompt.contains("2-3 sentences") })
        XCTAssertNotNil(briefCall, "Cycle 2 must have a brief generation LLM call")
        // The episodic summary is injected into the system prompt under "Recent context from prior sessions:"
        XCTAssertTrue(
            briefCall?.systemPrompt.contains("Episodic summary.") == true ||
            briefCall?.systemPrompt.contains("prior sessions") == true,
            "Cycle 2's system prompt must include the episodic summary from cycle 1. Got: \(briefCall?.systemPrompt.prefix(500) ?? "")"
        )
    }

    // MARK: - Group 3: ConversationState Carry-Forward

    // 3.1 — A full pipeline cycle writes a ConversationState row.
    func testFullPipelineCycleWritesConversationState() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m1", sender: "Alice", text: "Hi",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }
        _ = try await makeBriefEngine(db: db, mock: mock).processNewMessages()

        let state = try BriefRepository(database: db)
            .fetchConversationState(service: "signal", conversationID: "c1")
        XCTAssertNotNil(state, "ConversationState must be written after successful brief cycle")
        XCTAssertEqual(state?.lastSeenMessageId, "m1")
        XCTAssertNotNil(state?.rollingSummary)
    }

    // 3.2 — Two brief cycles on the same conversation produce exactly one ConversationState row.
    func testConversationStateIsUpsertedNotDuplicatedAcrossTwoCycles() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()

        // Cycle 1
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m1", sender: "Alice", text: "Hi",
                            timestamp: Date().addingTimeInterval(-60), isSent: false)
            try m.insert(d)
        }
        _ = try await makeBriefEngine(db: db, mock: mock).processNewMessages()

        // Cycle 2
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m2", sender: "Alice", text: "More",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }
        _ = try await makeBriefEngine(db: db, mock: mock).processNewMessages()

        // Must be exactly one state row
        let states = try await db.dbQueue.read { d in
            try ConversationState
                .filter(Column("service") == "signal")
                .filter(Column("conversationId") == "c1")
                .fetchAll(d)
        }
        XCTAssertEqual(states.count, 1,
            "ConversationState must be UPSERTed — one row per (service, conversationId), never duplicated")
        XCTAssertEqual(states.first?.lastSeenMessageId, "m2",
            "lastSeenMessageId must advance to the latest message")
    }

    // 3.3 — The rollingSummary from cycle 1 is injected into cycle 2's brief prompt.
    func testPreviousSummaryIsInjectedIntoNextCycleBriefPrompt() async throws {
        let db = try makeDB()

        // Cycle 1
        let mock1 = DynamicMockLLMClient()
        mock1.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m1", sender: "Alice", text: "Hi",
                            timestamp: Date().addingTimeInterval(-120), isSent: false)
            try m.insert(d)
        }
        _ = try await makeBriefEngine(db: db, mock: mock1).processNewMessages()

        let state = try BriefRepository(database: db)
            .fetchConversationState(service: "signal", conversationID: "c1")
        let storedSummary = try XCTUnwrap(state?.rollingSummary,
            "Cycle 1 must write a rollingSummary")

        // Cycle 2 with capturing mock
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m2", sender: "Alice", text: "More",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }
        let capturingMock = CapturingMockLLMClient()
        capturingMock.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])
        _ = try await makeBriefEngine(db: db, mock: capturingMock).processNewMessages()

        let briefCall = capturingMock.capturedCalls.first(where: { !$0.systemPrompt.contains("2-3 sentences") })
        XCTAssertNotNil(briefCall, "Cycle 2 must have a brief generation call")
        let userContent = briefCall?.userContent ?? ""
        XCTAssertTrue(
            userContent.contains(storedSummary) || userContent.contains("Previous summary:"),
            "Cycle 2's prompt must include the previous conversation summary. Got: \(userContent.prefix(400))"
        )
    }

    // MARK: - Group 4: ServiceHealth + Catch-Up

    // 4.1 — Successful poll writes ServiceHealth with status "ok".
    func testPollWritesHealthOkOnSuccess() async throws {
        let db = try makeDB()
        let engine = makeEngine(db: db)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")
        engine.register(adapter: adapter, config: signalConfig())

        await engine.pollAll()

        let health = try await db.dbQueue.read { d in try ServiceHealth.fetchOne(d, key: "signal") }
        XCTAssertEqual(health?.status, "ok")
        XCTAssertNotNil(health?.lastCheck)
        XCTAssertNil(health?.lastError)
    }

    // 4.2 — Failed fetch writes ServiceHealth with status "error" and stores no messages.
    func testPollWritesHealthErrorOnFetchFailure() async throws {
        let db = try makeDB()
        let engine = makeEngine(db: db)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.shouldFailFetch = true
        engine.register(adapter: adapter, config: signalConfig())

        await engine.pollAll()

        let health = try await db.dbQueue.read { d in try ServiceHealth.fetchOne(d, key: "signal") }
        XCTAssertEqual(health?.status, "error")
        XCTAssertNotNil(health?.lastError)
        let msgCount = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(msgCount, 0)
    }

    // 4.3 — Second poll uses the lastCheck stored after cycle 1 as the since date.
    func testSecondPollUsesPreviousLastCheckAsSinceDate() async throws {
        let db = try makeDB()
        let engine = makeEngine(db: db)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")
        engine.register(adapter: adapter, config: signalConfig())

        // Cycle 1
        await engine.pollAll()
        let lastCheck1 = try await db.dbQueue.read { d in
            try ServiceHealth.fetchOne(d, key: "signal")?.lastCheck
        }
        let t1 = try XCTUnwrap(lastCheck1)

        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // Cycle 2 — capture the FetchConfig received
        await engine.pollAll()
        let config2 = adapter.fetchConfigs.last

        if case .byTime(let since) = config2?.mode {
            XCTAssertGreaterThanOrEqual(since.timeIntervalSince1970, t1.timeIntervalSince1970 - 1,
                "Cycle 2's since date must come from the lastCheck stored after cycle 1")
        } else {
            XCTFail("FetchConfig mode must be .byTime")
        }
    }

    // 4.4 — checkCatchUp triggers an immediate poll when no ServiceHealth row exists.
    func testCheckCatchUpTriggersImmediatePollWhenNoHealthRow() async throws {
        let db = try makeDB()
        let engine = makeEngine(db: db)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        engine.register(adapter: adapter, config: signalConfig())

        let healthBefore = try await db.dbQueue.read { d in try ServiceHealth.fetchOne(d, key: "signal") }
        XCTAssertNil(healthBefore, "Precondition: no health row before start()")

        await engine.start()

        XCTAssertFalse(adapter.fetchConfigs.isEmpty,
            "checkCatchUp must trigger an immediate poll when no ServiceHealth row exists (first launch)")

        let healthAfter = try await db.dbQueue.read { d in try ServiceHealth.fetchOne(d, key: "signal") }
        XCTAssertNotNil(healthAfter, "ServiceHealth must be written after catch-up poll")
    }

    // 4.5 — checkCatchUp skips a service that was polled recently.
    func testCheckCatchUpSkipsServicePolledRecently() async throws {
        let db = try makeDB()
        let engine = makeEngine(db: db)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        engine.register(adapter: adapter, config: signalConfig())

        // Write a recent lastCheck (5 seconds ago, interval is 30 minutes)
        try await db.dbQueue.write { d in
            var health = ServiceHealth(service: "signal", status: "ok",
                                       lastCheck: Date().addingTimeInterval(-5),
                                       lastError: nil, retryAfter: nil)
            try health.save(d)
        }

        await engine.start()

        XCTAssertTrue(adapter.fetchConfigs.isEmpty,
            "checkCatchUp must NOT poll when the service was polled recently (elapsed < interval)")
    }

    // MARK: - Group 5: Pipeline Invariants

    // 5.1 — After a successful cycle, every message has a non-nil briefId.
    func testAfterSuccessfulCycleAllMessagesHaveBriefId() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        // All 3 messages listed in one spec — mock emits one card referencing all 3 IDs.
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1", "m2", "m3"])

        try await db.dbQueue.write { d in
            for (msgId, convId) in [("m1", "c1"), ("m2", "c1"), ("m3", "c2")] {
                var m = Message(briefId: nil, service: "signal", conversationId: convId,
                                messageId: msgId, sender: "Alice", text: "Hi",
                                timestamp: Date(), isSent: false)
                try m.insert(d)
            }
        }

        _ = try await makeBriefEngine(db: db, mock: mock).processNewMessages()

        let messages = try await db.dbQueue.read { d in try Message.fetchAll(d) }
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages.allSatisfy { $0.briefId != nil },
            "After a successful brief cycle, every message must be attached (briefId != nil)")

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 1)
    }

    // 5.2 — After a failed LLM cycle, all messages remain unattached.
    func testAfterFailedCycleAllMessagesRemainUnattached() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1", "m2"], fail: true)

        try await db.dbQueue.write { d in
            for msgId in ["m1", "m2"] {
                var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                                messageId: msgId, sender: "Alice", text: "Hi",
                                timestamp: Date(), isSent: false)
                try m.insert(d)
            }
        }

        _ = try? await makeBriefEngine(db: db, mock: mock).processNewMessages()

        let messages = try await db.dbQueue.read { d in try Message.fetchAll(d) }
        XCTAssertTrue(messages.allSatisfy { $0.briefId == nil },
            "When LLM fails, no message must be attached — atomicity must hold")

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 0, "No brief must be created when LLM fails")
    }

    // 5.3 — Brief count never exceeds the number of successful cycles.
    func testBriefCountNeverExceedsNumberOfSuccessfulCycles() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()

        for (msgId, cycle) in [("m1", 1), ("m2", 2), ("m3", 3)] {
            mock.specs["signal"] = .init(convId: "c1", messageIds: [msgId])
            try await db.dbQueue.write { d in
                var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                                messageId: msgId, sender: "Alice", text: "Cycle \(cycle)",
                                timestamp: Date(), isSent: false)
                try m.insert(d)
            }
            _ = try await makeBriefEngine(db: db, mock: mock).processNewMessages()
        }

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 3, "One brief per successful cycle — no duplicates")
    }

    // 5.4 — Two concurrent processNewMessages() calls produce exactly one brief.
    func testConcurrentBriefGenerationProducesExactlyOneBrief() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            messageId: "m1", sender: "Alice", text: "Hi",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }

        let briefEngine = makeBriefEngine(db: db, mock: mock)
        // Note: Because BackendWorkflowE2ETests is @MainActor, both async lets run on the
        // main actor. The briefingInFlight guard is set synchronously before the first await,
        // so when the second call starts, it sees briefingInFlight = true and returns nil
        // immediately. Exactly one brief is expected.
        async let r1 = briefEngine.processNewMessages()
        async let r2 = briefEngine.processNewMessages()
        _ = try await (r1, r2)

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 1,
            "briefingInFlight guard must prevent concurrent calls from producing more than one brief")

        let msg = try await db.dbQueue.read { d in
            try Message.filter(Column("messageId") == "m1").fetchOne(d)
        }
        XCTAssertNotNil(msg?.briefId, "m1 must be attached to the one brief that was created")
    }

    // 5.5 — lastCheck advances monotonically across poll cycles.
    func testServiceHealthLastCheckAdvancesMonotonicallyAcrossCycles() async throws {
        let db = try makeDB()
        let engine = makeEngine(db: db)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")
        engine.register(adapter: adapter, config: signalConfig())

        // Cycle 1
        await engine.pollAll()
        let t1 = try await db.dbQueue.read { d in
            try ServiceHealth.fetchOne(d, key: "signal")?.lastCheck
        }
        let lastCheck1 = try XCTUnwrap(t1, "lastCheck must be set after cycle 1")

        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // Cycle 2
        await engine.pollAll()
        let t2 = try await db.dbQueue.read { d in
            try ServiceHealth.fetchOne(d, key: "signal")?.lastCheck
        }
        let lastCheck2 = try XCTUnwrap(t2, "lastCheck must be set after cycle 2")

        XCTAssertGreaterThan(lastCheck2.timeIntervalSince1970, lastCheck1.timeIntervalSince1970,
            "lastCheck must advance strictly between cycles — regression would cause re-fetching stale messages")
    }

    // MARK: - Group 6: DB Error Boundaries

    // 6.1 — BriefEngine is atomic: no messages get a briefId when the LLM fails (before any DB write).
    func testBriefEngineIsAtomicOnPartialInsertFailure() async throws {
        // Note: This tests atomicity via LLM failure (before DB writes). DB-level transaction
        // atomicity (e.g., if insertBrief throws mid-write) is guaranteed by GRDB's
        // dbQueue.write transaction semantics, which cannot be easily injected in tests
        // without a custom DB wrapper.
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1", "m2", "m3"], fail: true)

        try await db.dbQueue.write { d in
            for msgId in ["m1", "m2", "m3"] {
                var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                                messageId: msgId, sender: "Alice", text: "Hi",
                                timestamp: Date(), isSent: false)
                try m.insert(d)
            }
        }

        _ = try? await makeBriefEngine(db: db, mock: mock).processNewMessages()

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 0, "No brief must exist when LLM fails")

        let messages = try await db.dbQueue.read { d in try Message.fetchAll(d) }
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages.allSatisfy { $0.briefId == nil },
            "All 3 messages must remain unattached when brief creation fails")
    }

    // 6.2 — Known gap: PollEngine does not expose a way to make store() throw.
    func testPollEngineStoreFailureDoesNotUpdateHealth() throws {
        throw XCTSkip("Known gap: PollEngine does not update ServiceHealth when store() fails. Requires DB injection infrastructure not yet available.")
    }

    // MARK: - Group 7: AppState Observation Contract

    // 7.1 — AppState.briefs populates after a full pipeline cycle.
    func testAppStateBriefsPopulatesAfterFullPipelineCycle() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        let (engine, _) = makeWiredPipeline(db: db, mock: mock)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")
        engine.register(adapter: adapter, config: signalConfig())

        await engine.pollAll()

        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        appState.refreshBriefs()

        XCTAssertEqual(appState.briefs.count, 1, "AppState.briefs must contain the generated brief")
        XCTAssertEqual(appState.unreadCount, 1, "unreadCount must be 1 for one unread (ready) brief")

        let briefID = try XCTUnwrap(appState.briefs.first?.id)
        appState.selectedBriefID = briefID
        XCTAssertNotNil(appState.selectedBrief, "selectedBrief must resolve after setting selectedBriefID")
    }

    // 7.2 — unreadCount decrements after markAsOpen.
    func testUnreadCountDecrementsAfterMarkAsOpen() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        let (engine, _) = makeWiredPipeline(db: db, mock: mock)
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")
        engine.register(adapter: adapter, config: signalConfig())

        await engine.pollAll()

        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        appState.refreshBriefs()

        XCTAssertEqual(appState.unreadCount, 1, "Precondition: one unread brief after pipeline cycle")

        let briefID = try XCTUnwrap(appState.briefs.first?.id)
        appState.markAsOpen(briefID: briefID)
        // markAsOpen calls refreshBriefs() internally — no explicit refresh needed.

        XCTAssertEqual(appState.unreadCount, 0, "unreadCount must be 0 after marking the brief as open")

        let updatedBrief = appState.briefs.first { $0.id == briefID }
        XCTAssertEqual(updatedBrief?.briefStatus, .open,
            "Brief status must be .open after markAsOpen")
    }
}
