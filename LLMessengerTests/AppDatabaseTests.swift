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
        XCTAssertEqual(config.fetchMode, "count")
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
    }
}
