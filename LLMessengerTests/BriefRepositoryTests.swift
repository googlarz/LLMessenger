// LLMessengerTests/BriefRepositoryTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class BriefRepositoryTests: XCTestCase {

    func testFetchUnattachedMessagesReturnsOnlyNullBriefId() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            var brief = Brief(createdAt: Date(), status: "ready",
                              services: "[]", openingSummary: nil,
                              notificationText: "x", episodicSummary: nil)
            try brief.insert(db)
            let briefId = brief.id

            for (i, briefIdValue) in [(0, nil as Int64?), (1, nil), (2, briefId)] {
                var msg = Message(briefId: briefIdValue, service: "telegram",
                                  conversationId: "c\(i)", messageId: "m\(i)",
                                  sender: "Alice", text: "msg \(i)",
                                  timestamp: Date(), isSent: false)
                try msg.insert(db)
            }
        }

        let repo = BriefRepository(database: db)
        let unattached = try repo.fetchUnattachedMessages()
        XCTAssertEqual(unattached.count, 2)
        XCTAssertTrue(unattached.allSatisfy { $0.briefId == nil })
    }

    func testAttachMessagesToBrief() throws {
        let db = try AppDatabase(inMemory: true)
        var briefId: Int64 = 0
        try db.dbQueue.write { db in
            var brief = Brief(createdAt: Date(), status: "ready",
                              services: "[]", openingSummary: nil,
                              notificationText: "x", episodicSummary: nil)
            try brief.insert(db)
            briefId = brief.id!

            for i in 0..<3 {
                var msg = Message(briefId: nil, service: "telegram",
                                  conversationId: "c\(i)", messageId: "m\(i)",
                                  sender: "A", text: "t",
                                  timestamp: Date(), isSent: false)
                try msg.insert(db)
            }
        }

        let repo = BriefRepository(database: db)
        let messages = try repo.fetchUnattachedMessages()
        try repo.attach(messages: messages, toBriefID: briefId)

        let stillUnattached = try repo.fetchUnattachedMessages()
        XCTAssertEqual(stillUnattached.count, 0)
    }

    func testFetchLatestUncompressedBriefReturnsMostRecent() throws {
        let db = try AppDatabase(inMemory: true)
        var newerId: Int64 = 0
        try db.dbQueue.write { db in
            var old = Brief(createdAt: Date(timeIntervalSinceNow: -3600),
                            status: "idle", services: "[]",
                            openingSummary: "old", notificationText: "x",
                            episodicSummary: "already compressed")
            try old.insert(db)
            var newer = Brief(createdAt: Date(),
                              status: "ready", services: "[]",
                              openingSummary: "newer", notificationText: "x",
                              episodicSummary: nil)
            try newer.insert(db)
            newerId = newer.id!
        }

        let repo = BriefRepository(database: db)
        let latest = try repo.fetchOldestUncompressedBrief()
        XCTAssertEqual(latest?.id, newerId)
        XCTAssertNil(latest?.episodicSummary)
    }

    func testFetchLatestUncompressedBriefReturnsNilWhenAllCompressed() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            var b = Brief(createdAt: Date(), status: "idle", services: "[]",
                          openingSummary: nil, notificationText: "x",
                          episodicSummary: "compressed")
            try b.insert(db)
        }
        let repo = BriefRepository(database: db)
        XCTAssertNil(try repo.fetchOldestUncompressedBrief())
    }

    func testFetchUnreadCountReturnsOnlyReadyBriefs() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        _ = try repo.insertBrief(makeBrief(status: "ready"))
        _ = try repo.insertBrief(makeBrief(status: "open"))
        XCTAssertEqual(try repo.fetchUnreadCount(), 1)
    }

    func testMarkAsOpenChangesStatus() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let id = try repo.insertBrief(makeBrief(status: "ready"))
        try repo.markAsOpen(briefID: id)
        let fetched = try repo.fetchBrief(id: id)
        XCTAssertEqual(fetched?.status, "open")
    }

    private func makeBrief(status: String) -> Brief {
        Brief(id: nil, createdAt: Date(), status: status, services: "[]",
              openingSummary: nil, notificationText: "test", episodicSummary: nil)
    }

    func testRecentEpisodicSummariesReturnsMostRecentFirst() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            for i in 0..<5 {
                var b = Brief(createdAt: Date(timeIntervalSinceNow: TimeInterval(-i * 100)),
                              status: "idle", services: "[\"signal\"]",
                              openingSummary: nil, notificationText: "x",
                              episodicSummary: "summary \(i)")
                try b.insert(db)
            }
        }

        let repo = BriefRepository(database: db)
        let recent = try repo.recentEpisodicSummaries(service: "signal", limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent[0].summary, "summary 0")
        XCTAssertEqual(recent[1].summary, "summary 1")
        XCTAssertEqual(recent[2].summary, "summary 2")
    }
}
