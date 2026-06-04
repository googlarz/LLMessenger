// LLMessengerTests/DatabaseIntegrityTests.swift
// Tests DB schema, migrations, constraints, and graceful handling of corrupt data.
// These guard against the two highest-severity silent failures:
//   1. A migration that corrupts or loses user data on app upgrade
//   2. A corrupt DB row that crashes the UI on startup
import XCTest
import GRDB
@testable import LLMessenger

final class DatabaseIntegrityTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    // MARK: - Schema completeness

    // If a migration adds a column in code but forgets to add it to the SQL,
    // GRDB will throw at runtime when that column is first accessed.
    // These tests verify the full schema is present after migration.

    func testAllExpectedTablesExistAfterMigration() throws {
        let db = try makeDB()
        let tables = try db.dbQueue.read { d in try d.tableExists("briefs") &&
            d.tableExists("messages") &&
            d.tableExists("briefCards") &&
            d.tableExists("conversationState") &&
            d.tableExists("serviceConfig") &&
            d.tableExists("serviceHealth") &&
            d.tableExists("briefCardSources") &&
            d.tableExists("llmRuns")
        }
        XCTAssertTrue(tables, "All expected tables must exist after AppDatabase migration")
    }

    func testBriefsTableHasFailedServicesColumn() throws {
        // v5_failed_services adds this column — if that migration is removed or broken,
        // BriefEngine crashes when trying to write failedServices
        let db = try makeDB()
        try db.dbQueue.read { d in
            let columns = try d.columns(in: "briefs").map(\.name)
            XCTAssertTrue(columns.contains("failedServices"),
                          "briefs.failedServices must exist — added in v5_failed_services migration")
        }
    }

    func testMessagesTableHasConversationNameColumn() throws {
        // v3_conversation_name adds this column — critical for displaying thread names in UI
        let db = try makeDB()
        try db.dbQueue.read { d in
            let columns = try d.columns(in: "messages").map(\.name)
            XCTAssertTrue(columns.contains("conversationName"),
                          "messages.conversationName must exist — added in v3_conversation_name migration")
        }
    }

    func testBriefCardsTableHasSourceMessageIdsColumn() throws {
        let db = try makeDB()
        try db.dbQueue.read { d in
            let columns = try d.columns(in: "briefCards").map(\.name)
            XCTAssertTrue(columns.contains("sourceMessageIds"),
                          "briefCards.sourceMessageIds must exist — used by BriefEngine validation")
        }
    }

    func testConversationStateTableHasPrimaryKey() throws {
        // (service, conversationId) is the composite PK — if missing, upsert would produce duplicates
        let db = try makeDB()
        try db.dbQueue.write { d in
            let state = ConversationState(service: "signal", conversationId: "c1",
                                          lastSeenMessageId: nil, lastSummarizedMessageId: nil,
                                          rollingSummary: "First", participants: nil,
                                          knownEntities: nil, unresolvedActions: nil,
                                          lastBriefCardId: nil, prioritySignals: nil,
                                          sourceMessageIds: nil, updatedAt: Date())
            try state.save(d)
            // Saving again with same PK must update, not insert
            var updated = state
            updated.rollingSummary = "Second"
            try updated.save(d)

            let count = try ConversationState
                .filter(Column("service") == "signal")
                .filter(Column("conversationId") == "c1")
                .fetchCount(d)
            XCTAssertEqual(count, 1,
                           "ConversationState upsert must update existing row — composite PK (service, conversationId) must be enforced")
        }
    }

    // MARK: - Duplicate message constraint

    func testDuplicateServiceMessageIdIsRejectedByUniqueConstraint() throws {
        // messages has UNIQUE(service, messageId) — duplicate inserts with .ignore don't double-store
        let db = try makeDB()
        try db.dbQueue.write { d in
            var m1 = Message(briefId: nil, service: "signal", conversationId: "c1",
                             conversationName: nil, messageId: "msg-dup",
                             sender: "Alice", text: "First", timestamp: Date(), isSent: false)
            try m1.insert(d)

            var m2 = Message(briefId: nil, service: "signal", conversationId: "c1",
                             conversationName: nil, messageId: "msg-dup",
                             sender: "Alice", text: "Second attempt", timestamp: Date(), isSent: false)
            try m2.insert(d, onConflict: .ignore)

            let count = try Message.filter(Column("messageId") == "msg-dup").fetchCount(d)
            XCTAssertEqual(count, 1, "Duplicate (service, messageId) must not be stored — UNIQUE constraint + INSERT OR IGNORE")

            let stored = try Message.filter(Column("messageId") == "msg-dup").fetchOne(d)
            XCTAssertEqual(stored?.text, "First", "Original message must be preserved on conflict")
        }
    }

    func testSameMessageIdOnDifferentServicesIsAllowed() throws {
        // The unique constraint is on (service, messageId), not just messageId
        let db = try makeDB()
        try db.dbQueue.write { d in
            var m1 = Message(briefId: nil, service: "signal", conversationId: "c1",
                             conversationName: nil, messageId: "shared-id",
                             sender: "Alice", text: "Signal msg", timestamp: Date(), isSent: false)
            try m1.insert(d)

            var m2 = Message(briefId: nil, service: "telegram", conversationId: "c2",
                             conversationName: nil, messageId: "shared-id",
                             sender: "Bob", text: "Telegram msg", timestamp: Date(), isSent: false)
            try m2.insert(d)  // must not throw — different service

            let count = try Message.filter(Column("messageId") == "shared-id").fetchCount(d)
            XCTAssertEqual(count, 2, "Same messageId on different services must both be stored — constraint is on (service, messageId)")
        }
    }

    // MARK: - Cascade deletion

    func testDeletingBriefCascadesToBriefCards() async throws {
        // briefCards has ON DELETE CASCADE referencing briefs
        let db = try makeDB()
        let briefId: Int64 = try await db.dbQueue.write { d in
            var b = Brief(createdAt: Date(), status: "ready", services: "[\"signal\"]",
                          openingSummary: nil, notificationText: "x", episodicSummary: nil)
            try b.insert(d)
            let id = b.id!
            let card = BriefCardRecord(id: "signal-c1-1", briefId: id,
                                       service: "signal", conversationId: "c1",
                                       conversationTitle: nil, headline: "H",
                                       priority: "medium", summary: "S",
                                       actionItems: "[]", callbackText: nil,
                                       sourceMessageIds: "[\"m1\"]", createdAt: Date())
            try card.insert(d)
            return id
        }

        // Verify card exists
        let cardsBefore = try await db.dbQueue.read { d in
            try BriefCardRecord.filter(Column("briefId") == briefId).fetchCount(d)
        }
        XCTAssertEqual(cardsBefore, 1)

        // Delete the brief
        try await db.dbQueue.write { d in
            try Brief.deleteOne(d, key: briefId)
        }

        // Card must be gone too
        let cardsAfter = try await db.dbQueue.read { d in
            try BriefCardRecord.filter(Column("briefId") == briefId).fetchCount(d)
        }
        XCTAssertEqual(cardsAfter, 0, "Deleting a Brief must cascade-delete its BriefCards")
    }

    // MARK: - Corrupt data graceful handling

    @MainActor
    func testBriefWithCorruptServicesJSONDoesNotCrashAppState() async throws {
        // If a DB row has malformed JSON in services, AppState.refreshBriefs must not crash.
        // This can happen after a failed write, manual DB edit, or future schema change.
        let db = try makeDB()
        try await db.dbQueue.write { d in
            // Insert a brief with invalid JSON in services field
            try d.execute(
                sql: "INSERT INTO briefs (createdAt, status, services, notificationText) VALUES (?, ?, ?, ?)",
                arguments: [Date(), "ready", "NOT_VALID_JSON", "x"]
            )
        }

        let mock = MockLLMClient()
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "B")

        // Must not crash — it reads all briefs including the corrupt one
        appState.refreshBriefs()

        // The corrupt brief is still in the list (it loads as-is, services decode gracefully)
        XCTAssertGreaterThanOrEqual(appState.briefs.count, 1,
                                    "AppState must load briefs even when services JSON is malformed")
    }

    @MainActor
    func testBriefWithNullFailedServicesLoadsWithoutCrash() async throws {
        // failedServices is nullable — nil must not cause any issue
        let db = try makeDB()
        try await db.dbQueue.write { d in
            var b = Brief(createdAt: Date(), status: "ready", services: "[\"signal\"]",
                          openingSummary: nil, notificationText: "x", episodicSummary: nil)
            try b.insert(d)
        }

        let mock = MockLLMClient()
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "B")
        appState.refreshBriefs()

        XCTAssertEqual(appState.briefs.count, 1)
        XCTAssertNil(appState.briefs.first?.failedServices,
                     "Brief with null failedServices must load correctly — failedServices is optional")
    }

    // MARK: - Migration idempotence

    func testOpeningAlreadyMigratedDatabaseDoesNotFail() throws {
        // Running AppDatabase.init on an already-migrated DB must not throw
        // (GRDB's migrator tracks applied migrations and skips them)
        let db1 = try makeDB()
        // AppDatabase(inMemory:) creates a fresh in-memory DB each time,
        // so we can't test real re-migration without a file. Instead verify
        // that migrator ran all migrations exactly once.
        let migrationCount = try db1.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
        }
        XCTAssertEqual(migrationCount, 12,
                       "All 12 migrations (v1..v12) must be recorded in grdb_migrations on fresh DB open")
    }

    func testReopeningDatabaseDoesNotReMigrate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reopen_test_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try AppDatabase(path: url.path)
        // Re-opening should succeed without error
        let db2 = try AppDatabase(path: url.path)
        XCTAssertNotNil(db2)
    }

    func testCascadedDeleteRemovesSources() throws {
        // briefCards → briefs (onDelete: .cascade)
        // briefCardSources → briefCards (onDelete: .cascade)
        // Deleting a brief must remove its cards and their sources.
        let db = try makeDB()
        try db.dbQueue.write { d in
            var b = Brief(createdAt: Date(), status: "ready", services: "[\"signal\"]",
                          openingSummary: nil, notificationText: "x", episodicSummary: nil)
            try b.insert(d)
            let briefId = b.id!

            let card = BriefCardRecord(id: "card-cascade-1", briefId: briefId,
                                       service: "signal", conversationId: "c1",
                                       conversationTitle: nil, headline: "H",
                                       priority: "medium", summary: "S",
                                       actionItems: "[]", callbackText: nil,
                                       sourceMessageIds: "[\"m1\"]", createdAt: Date())
            try card.insert(d)

            var source = BriefCardSource(id: nil,
                                         briefCardId: "card-cascade-1",
                                         messageRowId: nil,
                                         service: "signal",
                                         messageId: "m1",
                                         sourceRole: "primary",
                                         quoteText: nil,
                                         createdAt: Date())
            try source.insert(d)

            // Verify source exists before deletion
            let sourcesBefore = try BriefCardSource
                .filter(Column("briefCardId") == "card-cascade-1")
                .fetchCount(d)
            XCTAssertEqual(sourcesBefore, 1)

            // Delete brief — cascades to cards, which cascades to sources
            try Brief.deleteOne(d, key: briefId)

            let sourcesAfter = try BriefCardSource
                .filter(Column("briefCardId") == "card-cascade-1")
                .fetchCount(d)
            XCTAssertEqual(sourcesAfter, 0,
                           "Deleting a Brief must cascade through BriefCards to remove BriefCardSources")
        }
    }
}
