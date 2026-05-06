// LLMessenger/Core/Brief/BriefRepository.swift
import Foundation
import GRDB

enum BriefRepositoryError: Error, LocalizedError {
    case briefCardMissingSources

    var errorDescription: String? {
        switch self {
        case .briefCardMissingSources:
            return "Brief card must include at least one source message ID"
        }
    }
}

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
                        conversationName: conv.name,
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

    func fetchRecentContextMessages(
        service: String,
        conversationID: String,
        before date: Date,
        since: Date? = nil,
        limit: Int
    ) throws -> [Message] {
        try database.dbQueue.read { db in
            var request = Message
                .filter(Column("service") == service)
                .filter(Column("conversationId") == conversationID)
                .filter(Column("timestamp") < date)
                .filter(Column("isSent") == false)

            if let since {
                request = request.filter(Column("timestamp") >= since)
            }

            return try request
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
                .reversed()
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

    func upsertConversationState(_ state: ConversationState) throws {
        try database.dbQueue.write { db in
            try state.save(db)
        }
    }

    func fetchConversationState(service: String, conversationID: String) throws -> ConversationState? {
        try database.dbQueue.read { db in
            try ConversationState
                .filter(Column("service") == service)
                .filter(Column("conversationId") == conversationID)
                .fetchOne(db)
        }
    }

    func insertBriefCard(_ card: BriefCardRecord) throws {
        let sourceIDs = decodedStringArray(card.sourceMessageIds)
        guard !sourceIDs.isEmpty else { throw BriefRepositoryError.briefCardMissingSources }

        try database.dbQueue.write { db in
            try card.insert(db)
        }
    }

    func fetchBriefCards(briefID: Int64) throws -> [BriefCardRecord] {
        try database.dbQueue.read { db in
            try BriefCardRecord
                .filter(Column("briefId") == briefID)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    func fetchLatestBriefCard(service: String, conversationID: String) throws -> BriefCardRecord? {
        try database.dbQueue.read { db in
            try BriefCardRecord
                .filter(Column("service") == service)
                .filter(Column("conversationId") == conversationID)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    func insertBriefCardSources(_ sources: [BriefCardSource]) throws {
        try database.dbQueue.write { db in
            for var source in sources {
                try source.insert(db)
            }
        }
    }

    func fetchSources(briefCardID: String) throws -> [BriefCardSource] {
        try database.dbQueue.read { db in
            try BriefCardSource
                .filter(Column("briefCardId") == briefCardID)
                .order(Column("id").asc)
                .fetchAll(db)
        }
    }

    func fetchSourcesWithMessages(briefCardID: String) throws -> [(source: BriefCardSource, message: Message?)] {
        try database.dbQueue.read { db in
            let sources = try BriefCardSource
                .filter(Column("briefCardId") == briefCardID)
                .order(Column("id").asc)
                .fetchAll(db)

            var results: [(source: BriefCardSource, message: Message?)] = []
            for source in sources {
                let message = try Message.fetchOne(db, key: source.messageRowId)
                results.append((source: source, message: message))
            }
            return results
        }
    }

    func insertLLMRunRecord(_ run: LLMRunRecord) throws -> Int64 {
        try database.dbQueue.write { db in
            var record = run
            try record.insert(db)
            guard let id = record.id else { throw DatabaseError(message: "insertLLMRunRecord: no rowid after insert") }
            return id
        }
    }

    private func decodedStringArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return array.filter { !$0.isEmpty }
    }
}
