// LLMessengerTests/SearchTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class SearchTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func insertMessage(db: AppDatabase, text: String, sender: String = "Alice",
                               conversationId: String = "c1",
                               conversationName: String? = "Test Conv",
                               service: String = "signal") throws {
        try db.dbQueue.write { db in
            var msg = Message(briefId: nil, service: service,
                              conversationId: conversationId,
                              conversationName: conversationName,
                              messageId: UUID().uuidString,
                              sender: sender, text: text,
                              timestamp: Date(), isSent: false)
            try msg.insert(db)
        }
    }

    func testSearchMessagesFindsMatchingText() throws {
        let db = try makeDB()
        try insertMessage(db: db, text: "Let's grab coffee tomorrow morning")
        try insertMessage(db: db, text: "See you at the meeting")
        let repo = BriefRepository(database: db)

        let results = try repo.searchMessages(query: "coffee")

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].snippet.lowercased().contains("coffee"))
    }

    func testSearchMessagesReturnsEmptyForNoMatch() throws {
        let db = try makeDB()
        try insertMessage(db: db, text: "Hello world")
        let repo = BriefRepository(database: db)

        let results = try repo.searchMessages(query: "elephant")

        XCTAssertTrue(results.isEmpty)
    }

    func testSearchMessagesFiltersByService() throws {
        let db = try makeDB()
        try insertMessage(db: db, text: "coffee signal", service: "signal")
        try insertMessage(db: db, text: "coffee telegram", service: "telegram")
        let repo = BriefRepository(database: db)

        let results = try repo.searchMessages(query: "coffee", service: "signal")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].service, "signal")
    }

    func testSearchMessagesPrefixMatchWorks() throws {
        let db = try makeDB()
        try insertMessage(db: db, text: "Running the marathon this weekend")
        let repo = BriefRepository(database: db)

        let results = try repo.searchMessages(query: "marath")

        XCTAssertEqual(results.count, 1)
    }

    func testSearchBriefsFindsMatchingNotificationText() throws {
        let db = try makeDB()
        try db.dbQueue.write { db in
            var b = Brief(createdAt: Date(), status: "ready", services: "[]",
                          notificationText: "Dinner plans confirmed for Saturday",
                          pinned: false)
            try b.insert(db)
            var b2 = Brief(createdAt: Date(), status: "ready", services: "[]",
                           notificationText: "Work meeting scheduled",
                           pinned: false)
            try b2.insert(db)
        }
        let repo = BriefRepository(database: db)

        let results = try repo.searchBriefs(query: "dinner")

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].notificationText.lowercased().contains("dinner"))
    }

    func testSearchMessagesEmptyQueryReturnsEmpty() throws {
        let db = try makeDB()
        try insertMessage(db: db, text: "Hello world")
        let repo = BriefRepository(database: db)

        let results = try repo.searchMessages(query: "")
        XCTAssertTrue(results.isEmpty)
    }
}
