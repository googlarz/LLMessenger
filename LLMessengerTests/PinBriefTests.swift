// LLMessengerTests/PinBriefTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class PinBriefTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func insertBrief(db: AppDatabase, pinned: Bool = false) throws -> Int64 {
        try db.dbQueue.write { db in
            var brief = Brief(createdAt: Date(), status: "ready", services: "[]",
                              notificationText: "x", pinned: pinned)
            try brief.insert(db)
            return brief.id!
        }
    }

    func testSetPinnedTrue() throws {
        let db = try makeDB()
        let id = try insertBrief(db: db)
        let repo = BriefRepository(database: db)

        try repo.setPinned(briefID: id, pinned: true)

        let brief = try db.dbQueue.read { db in try Brief.fetchOne(db, key: id) }
        XCTAssertEqual(brief?.pinned, true)
    }

    func testSetPinnedFalse() throws {
        let db = try makeDB()
        let id = try insertBrief(db: db, pinned: true)
        let repo = BriefRepository(database: db)

        try repo.setPinned(briefID: id, pinned: false)

        let brief = try db.dbQueue.read { db in try Brief.fetchOne(db, key: id) }
        XCTAssertEqual(brief?.pinned, false)
    }

    func testFetchPinnedBriefsReturnsOnlyPinned() throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        _ = try insertBrief(db: db, pinned: false)
        _ = try insertBrief(db: db, pinned: false)
        let pinnedID = try insertBrief(db: db, pinned: true)

        let pinned = try repo.fetchPinnedBriefs()

        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(pinned.first?.id, pinnedID)
    }

    func testFetchPinnedBriefsIsOrderedByCreatedAtDesc() throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let old = try db.dbQueue.write { db -> Int64 in
            var b = Brief(createdAt: Date().addingTimeInterval(-3600), status: "ready",
                          services: "[]", notificationText: "old", pinned: true)
            try b.insert(db)
            return b.id!
        }
        let recent = try db.dbQueue.write { db -> Int64 in
            var b = Brief(createdAt: Date(), status: "ready",
                          services: "[]", notificationText: "recent", pinned: true)
            try b.insert(db)
            return b.id!
        }

        let pinned = try repo.fetchPinnedBriefs()
        XCTAssertEqual(pinned.first?.id, recent)
        XCTAssertEqual(pinned.last?.id, old)
    }

    func testFetchBriefsDateRange() throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let now = Date()
        try db.dbQueue.write { db in
            for offset in [-90.0, -1.0, 0.5] {
                var b = Brief(createdAt: now.addingTimeInterval(offset * 3600),
                              status: "ready", services: "[]", notificationText: "x")
                try b.insert(db)
            }
        }
        let from = now.addingTimeInterval(-2 * 3600)
        let to   = now

        let results = try repo.fetchBriefs(from: from, to: to)
        XCTAssertEqual(results.count, 1)
    }
}
