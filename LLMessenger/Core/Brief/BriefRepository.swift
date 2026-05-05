// LLMessenger/Core/Brief/BriefRepository.swift
import Foundation
import GRDB

struct BriefRepository {
    let database: AppDatabase

    func fetchUnattachedMessages() throws -> [Message] {
        try database.dbQueue.read { db in
            try Message
                .filter(Column("briefId") == nil)
                .filter(Column("isSent") == false)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    func attach(messages: [Message], toBriefID briefID: Int64) throws {
        try database.dbQueue.write { db in
            for var msg in messages {
                msg.briefId = briefID
                try msg.update(db)
            }
        }
    }

    func insertBrief(_ brief: Brief) throws -> Int64 {
        try database.dbQueue.write { db in
            var b = brief
            try b.insert(db)
            return b.id!
        }
    }

    func update(brief: Brief) throws {
        try database.dbQueue.write { db in
            var b = brief
            try b.update(db)
        }
    }

    func fetchBrief(id: Int64) throws -> Brief? {
        try database.dbQueue.read { db in
            try Brief.fetchOne(db, key: id)
        }
    }

    func latestBriefID() throws -> Int64? {
        try database.dbQueue.read { db in
            try Brief
                .order(Column("createdAt").desc)
                .fetchOne(db)?
                .id
        }
    }

    func fetchLatestUncompressedBrief() throws -> Brief? {
        try database.dbQueue.read { db in
            try Brief
                .filter(Column("episodicSummary") == nil)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    func recentEpisodicSummaries(limit: Int) throws -> [String] {
        try database.dbQueue.read { db in
            let briefs = try Brief
                .filter(Column("episodicSummary") != nil)
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
            return briefs.compactMap { $0.episodicSummary }
        }
    }

    func fetchMessages(forBriefID briefID: Int64) throws -> [Message] {
        try database.dbQueue.read { db in
            try Message
                .filter(Column("briefId") == briefID)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    func fetchAllBriefs() throws -> [Brief] {
        try database.dbQueue.read { db in
            try Brief
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    func fetchUnreadCount() throws -> Int {
        try database.dbQueue.read { db in
            try Brief.filter(Column("status") == "ready").fetchCount(db)
        }
    }

    func markAsOpen(briefID: Int64) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefs SET status = 'open' WHERE id = ?",
                arguments: [briefID]
            )
        }
    }
}
