// LLMessengerTests/BriefEngineHistoryTests.swift
// Tests BriefEngine.summarizeLast(hours:adapters:) — the on-demand historical brief path.
//
// summarizeLast is distinct from processNewMessages in two critical ways:
//   1. It does NOT call MemoryCompressor — no "2-3 sentences" LLM call precedes briefing.
//   2. It has a DB fallback: if an adapter returns nothing, it reads messages already
//      stored by the poll loop, so it can brief even when adapters are offline.
//
// These tests guard against: the fallback path silently producing no brief, the in-flight
// guard not applying to summarizeLast, and the time window not being respected.
import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class BriefEngineHistoryTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    // Pre-insert a message directly into the DB (simulates poll loop having stored it).
    private func insertStoredMessage(db: AppDatabase,
                                     service: String = "signal",
                                     convId: String = "c1",
                                     convName: String? = "Alice",
                                     messageId: String,
                                     sender: String = "Alice",
                                     text: String = "Hi",
                                     timeOffset: TimeInterval = -60) async throws {
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: service,
                            conversationId: convId, conversationName: convName,
                            messageId: messageId, sender: sender, text: text,
                            timestamp: Date().addingTimeInterval(timeOffset), isSent: false)
            try m.insert(d)
        }
    }

    // MARK: - Live adapter path

    func testSummarizeLastWithLiveAdapterCreatesBrief() async throws {
        let db = try makeDB()

        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", convName: "Alice", msgId: "m1",
                           sender: "Alice", text: "Hello")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let briefId = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])

        XCTAssertNotNil(briefId,
                        "summarizeLast must return a briefId when the adapter provides messages")
    }

    func testSummarizeLastWithLiveAdapterStoresMessagesInDB() async throws {
        let db = try makeDB()

        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1", sender: "Alice", text: "Test message")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])

        // Adapter-fetched messages must be persisted in the DB for the chat reply flow
        let count = try await db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(count, 1,
                       "summarizeLast must store adapter-fetched messages in the DB (needed for chat replies)")
    }

    func testSummarizeLastBriefHasCorrectService() async throws {
        let db = try makeDB()

        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let briefId = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])

        let brief = try XCTUnwrap(
            BriefRepository(database: db).fetchBrief(id: briefId!)
        )
        let services = (try? JSONDecoder().decode([String].self, from: Data(brief.services.utf8))) ?? []
        XCTAssertTrue(services.contains("signal"),
                      "Brief created by summarizeLast must record the correct service in its services list")
    }

    func testSummarizeLastBriefStatusIsReady() async throws {
        let db = try makeDB()

        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let briefId = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])

        let brief = try XCTUnwrap(BriefRepository(database: db).fetchBrief(id: briefId!))
        XCTAssertEqual(brief.briefStatus, .ready,
                       "summarizeLast must produce a brief with 'ready' status")
    }

    // MARK: - DB fallback path (adapter offline / returns nothing)

    func testSummarizeLastFallsBackToDBWhenAdapterReturnsNothing() async throws {
        let db = try makeDB()

        // Pre-store a message the way the poll loop would have
        try await insertStoredMessage(db: db, messageId: "stored-m1")

        // Adapter returns no conversations — simulates being offline or having nothing new
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        // adapter.conversations is empty by default

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["stored-m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let briefId = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])

        XCTAssertNotNil(briefId,
                        "summarizeLast must fall back to DB-stored messages when the adapter returns nothing — " +
                        "this is how historical briefs work when the adapter is offline")
    }

    func testSummarizeLastDBFallbackProducesReadyBrief() async throws {
        let db = try makeDB()
        try await insertStoredMessage(db: db, messageId: "db-m1", text: "Stored message")

        let adapter = FakeMessengerAdapter(serviceID: "signal")
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["db-m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let briefId = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])

        let brief = try XCTUnwrap(BriefRepository(database: db).fetchBrief(id: briefId!))
        XCTAssertEqual(brief.briefStatus, .ready,
                       "DB-fallback brief must also have 'ready' status")
    }

    func testSummarizeLastWithNoAdapterButDBMessages() async throws {
        // Service not in adapters dict but has stored messages — still must produce a brief
        // This covers the case where an adapter crashed but poll loop had already stored messages
        let db = try makeDB()
        try await insertStoredMessage(db: db, messageId: "orphan-m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["orphan-m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        // Pass empty adapters dict — service must be discovered from DB
        let briefId = try await engine.summarizeLast(hours: 24, adapters: [:])

        XCTAssertNotNil(briefId,
                        "summarizeLast must discover services from stored DB messages even if " +
                        "the adapter dict is empty — adapters may have crashed after storing messages")
    }

    // MARK: - No messages anywhere

    func testSummarizeLastReturnsNilWhenNoMessagesExist() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        let mock = DynamicMockLLMClient()
        // No spec needed — LLM must not be called if there's nothing to brief

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let result = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])

        XCTAssertNil(result, "summarizeLast must return nil when there are no messages — no brief to generate")
        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 0, "No brief must be stored when there is nothing to summarize")
    }

    func testSummarizeLastReturnsNilWhenEmptyAdaptersAndNoDB() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let result = try await engine.summarizeLast(hours: 24, adapters: [:])

        XCTAssertNil(result,
                     "summarizeLast with no adapters and no DB messages must return nil")
        XCTAssertEqual(mock.callCount, 0, "LLM must not be called when there are no messages at all")
    }

    // MARK: - Time window respected

    func testSummarizeLastExcludesMessagesBeyondTimeWindow() async throws {
        let db = try makeDB()
        // Insert message 48 hours ago — outside a 24h window
        try await insertStoredMessage(db: db, messageId: "old-m1", timeOffset: -48 * 3600)

        let adapter = FakeMessengerAdapter(serviceID: "signal")
        let mock = DynamicMockLLMClient()

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let result = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])

        XCTAssertNil(result,
                     "summarizeLast(hours:24) must not include a message from 48h ago — " +
                     "the time window must be respected")
        XCTAssertEqual(mock.callCount, 0,
                       "LLM must not be called when all stored messages are outside the time window")
    }

    func testSummarizeLastIncludesMessagesWithinTimeWindow() async throws {
        let db = try makeDB()
        // Message 1 hour ago — inside the 24h window
        try await insertStoredMessage(db: db, messageId: "recent-m1", timeOffset: -3600)

        let adapter = FakeMessengerAdapter(serviceID: "signal")
        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["recent-m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let result = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])

        XCTAssertNotNil(result,
                        "summarizeLast must include messages within the time window (1h < 24h)")
    }

    // MARK: - LLM failure

    func testSummarizeLastReturnsNilWhenLLMFails() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"], fail: true)

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let result = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])

        XCTAssertNil(result, "summarizeLast must return nil when the LLM call fails")
        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 0, "No brief must be stored when the LLM fails")
    }

    // MARK: - In-flight guard

    func testSummarizeLastInFlightGuardPreventsConcurrentRuns() async throws {
        let db = try makeDB()
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        adapter.addMessage(convId: "c1", msgId: "m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let adapters = ["signal": adapter as any MessengerAdapter]

        async let r1 = engine.summarizeLast(hours: 24, adapters: adapters)
        async let r2 = engine.summarizeLast(hours: 24, adapters: adapters)
        let (b1, b2) = try await (r1, r2)

        let successCount = [b1, b2].compactMap { $0 }.count
        XCTAssertEqual(successCount, 1,
                       "Concurrent summarizeLast calls must produce exactly one brief — in-flight guard applies here too")

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 1,
                       "In-flight guard on summarizeLast must prevent duplicate brief creation")
    }

    func testSummarizeLastAndProcessNewMessagesShareInFlightGuard() async throws {
        // briefingInFlight is shared — a running processNewMessages blocks summarizeLast and vice versa
        let db = try makeDB()
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal",
                            conversationId: "c1", conversationName: nil,
                            messageId: "m1", sender: "Alice", text: "Hi",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let adapter = FakeMessengerAdapter(serviceID: "signal")

        // First, run processNewMessages to consume the unattached message
        _ = try await engine.processNewMessages()

        // Add another message for summarizeLast to pick up
        try await db.dbQueue.write { d in
            var m2 = Message(briefId: nil, service: "signal",
                             conversationId: "c1", conversationName: nil,
                             messageId: "m2", sender: "Alice", text: "Hi again",
                             timestamp: Date(), isSent: false)
            try m2.insert(d)
        }

        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m2"])

        // Now run both concurrently — only one should succeed
        async let r1 = engine.processNewMessages()
        async let r2 = engine.summarizeLast(hours: 24, adapters: ["signal": adapter])
        let (b1, b2) = try await (r1, r2)

        let successCount = [b1, b2].compactMap { $0 }.count
        // At most 1 should succeed — they share the briefingInFlight guard
        XCTAssertLessThanOrEqual(successCount, 1,
                                 "processNewMessages and summarizeLast must share the briefingInFlight guard")
    }

    // MARK: - Multi-service

    func testSummarizeLastWithMultipleServicesProducesCardsForEach() async throws {
        let db = try makeDB()

        let signalAdapter = FakeMessengerAdapter(serviceID: "signal")
        signalAdapter.addMessage(convId: "s-c1", msgId: "sig-m1")

        let telegramAdapter = FakeMessengerAdapter(serviceID: "telegram")
        telegramAdapter.addMessage(convId: "t-c1", msgId: "tg-m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "s-c1", messageIds: ["sig-m1"])
        mock.specs["telegram"] = .init(convId: "t-c1", messageIds: ["tg-m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let briefId = try await engine.summarizeLast(
            hours: 24,
            adapters: ["signal": signalAdapter, "telegram": telegramAdapter]
        )

        let id = try XCTUnwrap(briefId, "Multi-service summarizeLast must produce a brief")
        let cards = try BriefRepository(database: db).fetchBriefCards(briefID: id)
        XCTAssertEqual(cards.count, 2, "summarizeLast must produce one card per service when both have messages")
        XCTAssertTrue(cards.contains { $0.service == "signal" })
        XCTAssertTrue(cards.contains { $0.service == "telegram" })
    }

    func testSummarizeLastPartialFailureStillProducesBriefForSuccessfulService() async throws {
        // When one service's LLM call fails, the other service's cards must still be included
        let db = try makeDB()

        let signalAdapter = FakeMessengerAdapter(serviceID: "signal")
        signalAdapter.addMessage(convId: "c1", msgId: "sig-m1")

        let telegramAdapter = FakeMessengerAdapter(serviceID: "telegram")
        telegramAdapter.addMessage(convId: "c2", msgId: "tg-m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["sig-m1"])
        mock.specs["telegram"] = .init(convId: "c2", messageIds: ["tg-m1"], fail: true)

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let briefId = try await engine.summarizeLast(
            hours: 24,
            adapters: ["signal": signalAdapter, "telegram": telegramAdapter]
        )

        let id = try XCTUnwrap(briefId,
                               "Partial failure in summarizeLast must still produce a brief for the succeeded service")
        let brief = try XCTUnwrap(BriefRepository(database: db).fetchBrief(id: id))
        let services = (try? JSONDecoder().decode([String].self, from: Data(brief.services.utf8))) ?? []
        XCTAssertTrue(services.contains("signal"), "Successful service must appear in brief")
        XCTAssertNotNil(brief.failedServices, "Failed service must be recorded in failedServices")
    }
}
