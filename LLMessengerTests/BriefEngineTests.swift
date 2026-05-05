// LLMessengerTests/BriefEngineTests.swift
import XCTest
@testable import LLMessenger

@MainActor
final class BriefEngineTests: XCTestCase {

    func setupDB(privacyMode: String) throws -> AppDatabase {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            var cfg = ServiceConfig.default(for: "telegram")
            cfg.privacyMode = privacyMode
            try cfg.insert(db)
        }
        return db
    }

    func insertUnattachedMessages(_ db: AppDatabase, count: Int) throws {
        try db.dbQueue.write { db in
            for i in 0..<count {
                var msg = Message(briefId: nil, service: "telegram",
                                  conversationId: "c1", messageId: "m\(i)",
                                  sender: "Alice", text: "msg \(i)",
                                  timestamp: Date(), isSent: false)
                try msg.insert(db)
            }
        }
    }

    func testNoUnattachedMessagesCreatesNoBrief() async throws {
        let db = try setupDB(privacyMode: "on_demand")
        let mock = MockLLMClient()
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        XCTAssertNil(id)
        XCTAssertEqual(mock.calls.count, 0)
    }

    func testOnDemandModeCreatesBriefWithoutLLMCall() async throws {
        let db = try setupDB(privacyMode: "on_demand")
        try insertUnattachedMessages(db, count: 3)
        let mock = MockLLMClient()
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        XCTAssertNotNil(id)
        XCTAssertEqual(mock.calls.count, 0)

        let repo = BriefRepository(database: db)
        let brief = try repo.fetchBrief(id: id!)!
        XCTAssertNil(brief.openingSummary)
        XCTAssertTrue(brief.notificationText.contains("3"))
    }

    func testEagerModeCallsSummarizer() async throws {
        let db = try setupDB(privacyMode: "eager")
        try insertUnattachedMessages(db, count: 2)
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Alice said hi twice.", inputTokens: 10, outputTokens: 5)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()
        XCTAssertNotNil(id)
        XCTAssertEqual(mock.calls.count, 1)

        let repo = BriefRepository(database: db)
        let brief = try repo.fetchBrief(id: id!)!
        XCTAssertEqual(brief.openingSummary, "Alice said hi twice.")
    }

    func testCompressesPreviousBriefBeforeCreatingNewOne() async throws {
        let db = try setupDB(privacyMode: "on_demand")
        var prevId: Int64 = 0
        try await db.dbQueue.write { db in
            var prev = Brief(createdAt: Date(timeIntervalSinceNow: -3600),
                             status: "idle", services: "[\"telegram\"]",
                             openingSummary: nil, notificationText: "x",
                             episodicSummary: nil)
            try prev.insert(db)
            prevId = prev.id!
            var msg = Message(briefId: prevId, service: "telegram",
                              conversationId: "c0", messageId: "m_old",
                              sender: "Bob", text: "old message",
                              timestamp: Date(timeIntervalSinceNow: -3600),
                              isSent: false)
            try msg.insert(db)
        }
        try insertUnattachedMessages(db, count: 1)

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Bob talked about old stuff.", inputTokens: 5, outputTokens: 3)
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        XCTAssertEqual(mock.calls.count, 1)
        let repo = BriefRepository(database: db)
        let prev = try repo.fetchBrief(id: prevId)!
        XCTAssertEqual(prev.episodicSummary, "Bob talked about old stuff.")
    }

    func testAttachesMessagesToNewBrief() async throws {
        let db = try setupDB(privacyMode: "on_demand")
        try insertUnattachedMessages(db, count: 4)
        let mock = MockLLMClient()
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")

        let id = try await engine.processNewMessages()

        let repo = BriefRepository(database: db)
        let attached = try repo.fetchMessages(forBriefID: id!)
        XCTAssertEqual(attached.count, 4)

        let stillUnattached = try repo.fetchUnattachedMessages()
        XCTAssertEqual(stillUnattached.count, 0)
    }
}
