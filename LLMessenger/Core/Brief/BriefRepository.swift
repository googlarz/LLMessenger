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

    func storeSentMessage(service: String, conversationID: String, text: String) throws {
        try database.dbQueue.write { db in
            var record = Message(
                briefId: nil,
                service: service,
                conversationId: conversationID,
                messageId: "sent-\(UUID().uuidString)",
                sender: "me",
                text: text,
                timestamp: Date(),
                isSent: true
            )
            try record.insert(db, onConflict: .ignore)
        }
    }

    func markAsSent(messageID: String, service: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE messages SET isSent = 1 WHERE service = ? AND messageId = ?",
                arguments: [service, messageID]
            )
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
            guard let id = b.id else { throw DatabaseError(message: "insertBrief: no rowid after insert") }
            return id
        }
    }

    func update(brief: Brief) throws {
        try database.dbQueue.write { db in
            let b = brief
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

    // Returns the oldest uncompressed brief so compression runs oldest-first,
    // preventing new briefs from starving older ones of episodic summaries.
    func fetchOldestUncompressedBrief() throws -> Brief? {
        try database.dbQueue.read { db in
            try Brief
                .filter(Column("episodicSummary") == nil)
                .order(Column("createdAt").asc)
                .fetchOne(db)
        }
    }

    func recentEpisodicSummaries(service: String, limit: Int) throws -> [(summary: String, createdAt: Date)] {
        try database.dbQueue.read { db in
            let pattern = "%\"" + service + "\"%"
            let briefs = try Brief
                .filter(Column("episodicSummary") != nil)
                .filter(sql: "services LIKE ?", arguments: [pattern])
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
            return briefs.compactMap { b in
                b.episodicSummary.map { ($0, b.createdAt) }
            }
        }
    }

    // INSERT OR IGNORE for each message; returns only the newly inserted ones.
    // Used by summarizeLast to persist adapter-fetched messages so chat works.
    @discardableResult
    func storeMessages(from result: AdapterFetchResult, service: String) throws -> [Message] {
        var stored: [Message] = []
        try database.dbQueue.write { db in
            for conv in result.conversations {
                for msg in conv.messages {
                    var record = Message(
                        briefId: nil,
                        service: service,
                        conversationId: conv.id,
                        messageId: msg.id,
                        sender: msg.sender,
                        text: msg.text,
                        timestamp: msg.timestamp,
                        isSent: false
                    )
                    try record.insert(db, onConflict: .ignore)
                    if db.changesCount > 0 {
                        stored.append(record)
                    } else if let existing = try Message
                        .filter(Column("service") == service)
                        .filter(Column("messageId") == msg.id)
                        .fetchOne(db), existing.briefId == nil {
                        stored.append(existing)
                    }
                }
            }
        }
        return stored
    }

    /// Returns stored messages for a given service within [since, now], regardless of brief attachment.
    func fetchMessages(service: String, since: Date) throws -> [Message] {
        try database.dbQueue.read { db in
            try Message
                .filter(Column("service") == service)
                .filter(Column("timestamp") > since)
                .filter(Column("isSent") == false)
                .order(Column("timestamp").asc)
                .fetchAll(db)
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
            try Brief.filter(Column("status") == BriefStatus.ready.rawValue).fetchCount(db)
        }
    }

    func markAsOpen(briefID: Int64) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefs SET status = ? WHERE id = ?",
                arguments: [BriefStatus.open.rawValue, briefID]
            )
        }
    }
}
