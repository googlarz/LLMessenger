// LLMessengerTests/FrontendRobustnessTests.swift
// Tests every backend→frontend contract that could cause a crash or inconsistent state.
//
// The frontend has one force-unwrap (ChatViewModel.loadBrief: brief.id!), reads BriefCardRecord
// JSON fields as raw strings, and computes selectedBrief from a cached array after every refresh.
// These tests verify that the backend upholds each contract so those paths are always safe.
import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class FrontendRobustnessTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func makeAppState(db: AppDatabase) -> AppState {
        AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "BASE")
    }

    /// Inserts a Brief using only the fields accepted by the existing memberwise init.
    private func insertBrief(db: AppDatabase,
                             status: String = "ready",
                             services: String = #"["signal"]"#,
                             openingSummary: String? = nil,
                             episodicSummary: String? = nil) async throws -> Int64 {
        try await db.dbQueue.write { d in
            var b = Brief(createdAt: Date(), status: status, services: services,
                          openingSummary: openingSummary, notificationText: "x",
                          episodicSummary: episodicSummary)
            try b.insert(d)
            return b.id!
        }
    }

    /// Inserts a BriefCardRecord directly into the DB, bypassing insertBriefCard's guard.
    /// Used to inject corrupt JSON and verify the read path is crash-safe.
    private func insertBriefCardDirect(db: AppDatabase,
                                       briefId: Int64,
                                       actionItems: String,
                                       sourceMessageIds: String) async throws {
        try await db.dbQueue.write { d in
            let card = BriefCardRecord(
                id: UUID().uuidString,
                briefId: briefId,
                service: "signal",
                conversationId: "c1",
                conversationTitle: nil,
                headline: "Test card",
                priority: "normal",
                summary: "A test summary.",
                actionItems: actionItems,
                callbackText: nil,
                sourceMessageIds: sourceMessageIds,
                createdAt: Date()
            )
            try card.insert(d)
        }
    }

    // MARK: - brief.id! force-unwrap contract
    //
    // ChatViewModel.loadBrief line 21: `brief.id!`
    // This is the only force-unwrap in the UI layer. The contract: every Brief returned by
    // fetchAllBriefs() must have a non-nil id. GRDB assigns rowIDs on insert, so this is always
    // true — but we must prove it with a test, not rely on assumption.

    func testFetchAllBriefsNeverReturnsNilId() async throws {
        let db = try makeDB()
        _ = try await insertBrief(db: db, status: "ready")
        _ = try await insertBrief(db: db, status: "open")
        _ = try await insertBrief(db: db, status: "idle")

        let repository = BriefRepository(database: db)
        let briefs = try repository.fetchAllBriefs()

        XCTAssertFalse(briefs.isEmpty, "Precondition: briefs must be present in DB")
        for brief in briefs {
            XCTAssertNotNil(brief.id,
                            "fetchAllBriefs must never return a Brief with nil id — " +
                            "ChatViewModel.loadBrief force-unwraps brief.id on every invocation")
        }
    }

    func testLoadBriefWithDatabaseBriefDoesNotCrash() async throws {
        let db = try makeDB()
        let briefId = try await insertBrief(db: db)
        try await db.dbQueue.write { d in
            var msg = Message(briefId: briefId, service: "signal",
                              conversationId: "c1", messageId: "m1",
                              sender: "Alice", text: "Hi",
                              timestamp: Date(), isSent: false)
            try msg.insert(d)
        }

        let appState = makeAppState(db: db)
        appState.refreshBriefs()
        let brief = try XCTUnwrap(appState.briefs.first, "Precondition: must have a brief after refresh")
        let vm = ChatViewModel(appState: appState)

        // Must not crash — this exercises brief.id! on a real DB-fetched Brief
        try await vm.loadBrief(brief)

        XCTAssertFalse(vm.threadItems.isEmpty,
                       "loadBrief must populate threadItems from the attached messages")
    }

    // MARK: - fetchBriefCards contract
    //
    // BriefProseView calls fetchBriefCards and iterates the result.
    // An unknown briefID must return [] — not nil, not crash.
    // Corrupt JSON in actionItems/sourceMessageIds must not crash the read path.

    func testFetchBriefCardsForUnknownBriefIDReturnsEmptyArray() throws {
        let db = try makeDB()
        let repository = BriefRepository(database: db)
        let cards = try repository.fetchBriefCards(briefID: 99_999)
        XCTAssertEqual(cards.count, 0,
                       "fetchBriefCards with a non-existent briefID must return [] — " +
                       "never nil, never crash — BriefProseView iterates the result unconditionally")
    }

    func testFetchBriefCardsWithMalformedJSONFieldsDoesNotCrash() async throws {
        let db = try makeDB()
        let briefId = try await insertBrief(db: db)
        // Inject corrupt JSON by bypassing the guard in insertBriefCard
        try await insertBriefCardDirect(db: db, briefId: briefId,
                                        actionItems: "NOT_VALID_JSON",
                                        sourceMessageIds: "ALSO_NOT_JSON")

        let repository = BriefRepository(database: db)
        let cards = try repository.fetchBriefCards(briefID: briefId)

        XCTAssertEqual(cards.count, 1,
                       "fetchBriefCards must return the card even when JSON fields are corrupt — " +
                       "BriefCardRecord stores them as raw Strings, not decoded on read")
        XCTAssertEqual(cards[0].actionItems, "NOT_VALID_JSON",
                       "actionItems must be returned verbatim — it is a raw String, never decoded on read")
        XCTAssertEqual(cards[0].sourceMessageIds, "ALSO_NOT_JSON",
                       "sourceMessageIds must be returned verbatim — raw String, never decoded on read")
    }

    // MARK: - Stale selectedBriefID
    //
    // AppState.selectedBrief = briefs.first { $0.id == selectedBriefID }
    // If the selected brief is deleted and briefs are refreshed, selectedBriefID is stale.
    // selectedBrief must return nil — not crash, not return the wrong brief.

    func testSelectedBriefReturnsNilAfterBriefDeletedAndRefreshed() async throws {
        let db = try makeDB()
        let briefId = try await insertBrief(db: db)
        let appState = makeAppState(db: db)
        appState.refreshBriefs()
        appState.selectedBriefID = briefId
        XCTAssertNotNil(appState.selectedBrief, "Precondition: selectedBrief must resolve before deletion")

        // Simulate brief being pruned / replaced
        try await db.dbQueue.write { d in
            try d.execute(sql: "DELETE FROM briefs WHERE id = ?", arguments: [briefId])
        }
        appState.refreshBriefs()

        XCTAssertNil(appState.selectedBrief,
                     "selectedBrief must return nil after the targeted brief is deleted and briefs are refreshed — " +
                     "a stale selectedBriefID must never crash or return wrong data")
        XCTAssertTrue(appState.briefs.isEmpty,
                      "briefs must be empty after all briefs are deleted")
    }

    // MARK: - markAsOpen contract
    //
    // AppState.markAsOpen silently ignores errors — the UI must stay consistent regardless.

    func testMarkAsOpenWithUnknownBriefIDDoesNotCrash() throws {
        let db = try makeDB()
        let appState = makeAppState(db: db)
        appState.refreshBriefs()

        // Must not crash, must not throw (AppState catches and ignores errors)
        appState.markAsOpen(briefID: 99_999)

        XCTAssertTrue(appState.briefs.isEmpty,
                      "briefs must remain empty — markAsOpen on unknown ID must be a no-op")
    }

    func testMarkAsOpenIsIdempotent() async throws {
        let db = try makeDB()
        let briefId = try await insertBrief(db: db, status: "ready")
        let appState = makeAppState(db: db)
        appState.refreshBriefs()
        XCTAssertEqual(appState.briefs.first?.briefStatus, .ready, "Precondition: status must be ready")

        // Call twice — must not crash, must not corrupt state
        appState.markAsOpen(briefID: briefId)
        appState.markAsOpen(briefID: briefId)

        XCTAssertEqual(appState.briefs.first?.briefStatus, .open,
                       "markAsOpen must be idempotent — calling twice must produce the same result without crashing")
    }

    func testMarkAsOpenDoesNotAffectOtherBriefs() async throws {
        let db = try makeDB()
        let id1 = try await insertBrief(db: db, status: "ready")
        let id2 = try await insertBrief(db: db, status: "ready")
        let appState = makeAppState(db: db)
        appState.refreshBriefs()

        appState.markAsOpen(briefID: id1)

        let byID = Dictionary(uniqueKeysWithValues: appState.briefs.compactMap { b in
            b.id.map { ($0, b.briefStatus) }
        })
        XCTAssertEqual(byID[id1], .open,
                       "markAsOpen must set the target brief's status to open")
        XCTAssertEqual(byID[id2], .ready,
                       "markAsOpen must not affect other briefs — SQL WHERE id = ? must be scoped correctly")
    }

    // MARK: - Chaos test: corrupt JSON in every nullable field
    //
    // Worst-case DB state: every JSON-bearing field holds invalid data.
    // The full frontend lifecycle (refreshBriefs → select → loadBrief → markAsOpen) must complete
    // without crashing. The backend must degrade gracefully, never panic the UI.

    func testFullLifecycleWithAllCorruptNullableFieldsDoesNotCrash() async throws {
        let db = try makeDB()

        // Insert a Brief where every JSON/optional field holds garbage
        let briefId = try await db.dbQueue.write { d -> Int64 in
            try d.execute(
                sql: """
                    INSERT INTO briefs (createdAt, status, services, failedServices,
                                        openingSummary, notificationText, episodicSummary)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [Date(), "ready",
                            "NOT_JSON_ARRAY",        // briefServices() returns []
                            "<<<CORRUPT>>>",          // failedServices is displayed as-is
                            "{{{invalid",             // openingSummary shown as-is
                            "ok",
                            "[}broken"]               // episodicSummary shown as-is
            )
            return d.lastInsertedRowID
        }

        // Inject BriefCardRecord with corrupt JSON in both JSON fields
        try await insertBriefCardDirect(db: db, briefId: briefId,
                                        actionItems: "CORRUPT",
                                        sourceMessageIds: "CORRUPT")

        // Attach a message so loadBrief has data to display
        try await db.dbQueue.write { d in
            var msg = Message(briefId: briefId, service: "signal",
                              conversationId: "c1", messageId: "m1",
                              sender: "Alice", text: "Hi",
                              timestamp: Date(), isSent: false)
            try msg.insert(d)
        }

        let appState = makeAppState(db: db)

        // Step 1: refreshBriefs must not crash with corrupt Brief fields
        appState.refreshBriefs()
        XCTAssertEqual(appState.briefs.count, 1,
                       "refreshBriefs must load briefs even with corrupt JSON fields")

        // Step 2: selectedBrief must resolve from selectedBriefID
        appState.selectedBriefID = briefId
        let brief = try XCTUnwrap(appState.selectedBrief,
                                   "selectedBrief must resolve even when the Brief's JSON fields are corrupt")

        // Step 3: loadBrief must not crash on brief.id! (the only UI force-unwrap)
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)

        // Step 4: markAsOpen must not crash
        appState.markAsOpen(briefID: briefId)
        XCTAssertEqual(appState.briefs.first?.briefStatus, .open,
                       "markAsOpen must succeed in the chaos scenario — corrupt JSON must not block status update")

        // Step 5: unreadCount must be >= 0 — no crash from corrupt services JSON
        XCTAssertGreaterThanOrEqual(appState.unreadCount, 0,
                                    "unreadCount must remain non-negative regardless of corrupt DB state")
    }
}
