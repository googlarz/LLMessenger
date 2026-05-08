import XCTest
import GRDB
@testable import LLMessenger

final class AppDatabaseTests: XCTestCase {

    func testDatabaseCreatesTablesOnInit() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("briefs"))
            XCTAssertTrue(try db.tableExists("messages"))
            XCTAssertTrue(try db.tableExists("serviceConfig"))
            XCTAssertTrue(try db.tableExists("serviceHealth"))
            XCTAssertTrue(try db.tableExists("conversationState"))
            XCTAssertTrue(try db.tableExists("briefCards"))
            XCTAssertTrue(try db.tableExists("briefCardSources"))
            XCTAssertTrue(try db.tableExists("llmRuns"))
        }
    }

    func testMessageInsertAndFetch() throws {
        let db = try AppDatabase(inMemory: true)
        var message = Message(
            briefId: nil, service: "telegram",
            conversationId: "123", messageId: "msg_1",
            sender: "João", text: "hello", timestamp: Date(), isSent: false
        )
        try db.dbQueue.write { db in try message.insert(db) }

        let fetched = try db.dbQueue.read { db in
            try Message.fetchOne(db, key: message.id!)
        }
        XCTAssertEqual(fetched?.text, "hello")
    }

    func testMessageDeduplicatesByServiceAndMessageId() throws {
        let db = try AppDatabase(inMemory: true)
        var msg = Message(briefId: nil, service: "telegram", conversationId: "123",
                          messageId: "msg_1", sender: "João", text: "hello",
                          timestamp: Date(), isSent: false)
        try db.dbQueue.write { db in
            try msg.insert(db)
            XCTAssertThrowsError(try msg.insert(db))
        }
    }

    func testServiceConfigDefault() throws {
        let config = ServiceConfig.default(for: "telegram")
        XCTAssertEqual(config.service, "telegram")
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.pollIntervalMinutes, 30)
        XCTAssertEqual(config.fetchMode, "time")
        XCTAssertEqual(config.fetchLimit, 50)
        XCTAssertEqual(config.privacyMode, "on_demand")
    }

    func testBriefInsertAndFetch() throws {
        let db = try AppDatabase(inMemory: true)
        var brief = Brief(
            createdAt: Date(), status: "ready",
            services: "[\"telegram\"]",
            openingSummary: nil,
            notificationText: "3 new messages",
            episodicSummary: nil
        )
        try db.dbQueue.write { db in try brief.insert(db) }
        let fetched = try db.dbQueue.read { db in
            try Brief.fetchOne(db, key: brief.id!)
        }
        XCTAssertEqual(fetched?.notificationText, "3 new messages")
        XCTAssertNil(fetched?.openingSummary)
        XCTAssertEqual(fetched?.pinned, false, "Newly inserted brief without explicit pinned should default to false")
    }

    func testBriefsPinnedColumnExists() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.read { db in
            let columns = try db.columns(in: "briefs")
            XCTAssertTrue(columns.contains { $0.name == "pinned" },
                          "briefs table must have a 'pinned' column")
        }
    }

    func testMessagesFTSTableExists() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.read { db in
            let exists = try db.tableExists("messages_fts")
            XCTAssertTrue(exists, "messages_fts virtual table must exist after migration")
        }
    }

    func testBriefsFTSTableExists() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.read { db in
            let exists = try db.tableExists("briefs_fts")
            XCTAssertTrue(exists, "briefs_fts virtual table must exist after migration")
        }
    }

    func testMessagesFTSTriggerKeepsSync() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            var msg = Message(briefId: nil, service: "signal", conversationId: "c1",
                              messageId: "m1", sender: "Alice",
                              text: "Hello world from Alice",
                              timestamp: Date(), isSent: false)
            try msg.insert(db)
        }
        try db.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'world'")
            XCTAssertEqual(rows.count, 1)
        }
    }

    func testBriefsFTSTriggerKeepsSync() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            var brief = Brief(
                createdAt: Date(), status: "ready",
                services: "[\"telegram\"]",
                openingSummary: nil,
                notificationText: "Breaking news from the agency",
                episodicSummary: nil
            )
            try brief.insert(db)
        }
        try db.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT rowid FROM briefs_fts WHERE briefs_fts MATCH 'breaking'")
            XCTAssertEqual(rows.count, 1, "briefs_fts virtual table must be kept in sync with briefs table")
        }
    }
}
