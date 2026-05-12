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
        // Exclude messages older than 7 days — they won't improve a current brief and
        // would silently bloat the LLM prompt on every cycle until attached or pruned.
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return try database.dbQueue.read { db in
            try Message
                .filter(Column("briefId") == nil)
                .filter(Column("isSent") == false)
                .filter(Column("timestamp") >= cutoff)
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
    // Briefs where episodicSummary == "" have failed compression and are excluded
    // (empty string is the sentinel written by BriefEngine when compression fails).
    func fetchOldestUncompressedBrief() throws -> Brief? {
        try database.dbQueue.read { db in
            try Brief
                .filter(Column("episodicSummary") == nil)
                .order(Column("createdAt").asc)
                .fetchOne(db)
        }
    }

    // Writes episodicSummary for a brief — used by MemoryCompressor on success and,
    // with an empty string, as a sentinel when compression permanently fails.
    func setEpisodicSummary(briefID: Int64, summary: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefs SET episodicSummary = ? WHERE id = ?",
                arguments: [summary, briefID]
            )
        }
    }

    func recentEpisodicSummaries(service: String, limit: Int) throws -> [(summary: String, createdAt: Date)] {
        try database.dbQueue.read { db in
            let pattern = "%\"" + service + "\"%"
            let briefs = try Brief
                .filter(Column("episodicSummary") != nil)
                .filter(sql: "episodicSummary != ''")   // exclude compression-failed sentinel
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
                        isSent: msg.isFromMe
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

    func setPinned(briefID: Int64, pinned: Bool) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefs SET pinned = ? WHERE id = ?",
                arguments: [pinned ? 1 : 0, briefID]
            )
        }
    }

    func fetchPinnedBriefs() throws -> [Brief] {
        try database.dbQueue.read { db in
            try Brief
                .filter(Column("pinned") == true)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// Fetches briefs whose createdAt falls within [from, to] inclusive.
    func fetchBriefs(from: Date, to: Date) throws -> [Brief] {
        try database.dbQueue.read { db in
            try Brief
                .filter(Column("createdAt") >= from)
                .filter(Column("createdAt") <= to)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// Full-text search over message content using FTS5.
    /// Returns up to `limit` results ordered by FTS5 relevance rank.
    /// An empty query returns an empty array immediately.
    func searchMessages(query: String,
                        service: String? = nil,
                        since: Date? = nil,
                        limit: Int = 50) throws -> [MessageSearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try database.dbQueue.read { db in
            // Wrap in double-quotes so FTS5 treats the input as a quoted phrase/prefix,
            // preventing reserved tokens (AND, OR, NOT, NEAR, leading "-") from being
            // interpreted as operators and causing unexpected results or query errors.
            let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
            let sanitized = "\"\(escaped)\"*"
            var sql = """
                SELECT m.id as messageRowId, m.service, m.conversationId,
                       m.conversationName, m.sender, m.timestamp, m.briefId as briefID,
                       snippet(messages_fts, 0, '<<', '>>', '\u{2026}', 15) as snippet
                FROM messages_fts
                JOIN messages m ON m.id = messages_fts.rowid
                WHERE messages_fts MATCH ?
            """
            var args: [DatabaseValueConvertible] = [sanitized]

            if let service {
                sql += " AND m.service = ?"
                args.append(service)
            }
            if let since {
                sql += " AND m.timestamp >= ?"
                args.append(since)
            }
            sql += " ORDER BY rank LIMIT ?"
            args.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map { row -> MessageSearchResult in
                    MessageSearchResult(
                        messageRowId: row["messageRowId"],
                        service:      row["service"],
                        conversationId: row["conversationId"],
                        conversationName: row["conversationName"],
                        sender:       row["sender"],
                        snippet:      row["snippet"] ?? query,
                        timestamp:    row["timestamp"],
                        briefID:      row["briefID"]
                    )
                }
        }
    }

    /// Full-text search over brief notification text and opening summary.
    func searchBriefs(query: String,
                      since: Date? = nil,
                      limit: Int = 20) throws -> [Brief] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try database.dbQueue.read { db in
            let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
            let sanitized = "\"\(escaped)\"*"
            var sql = """
                SELECT b.*
                FROM briefs_fts
                JOIN briefs b ON b.id = briefs_fts.rowid
                WHERE briefs_fts MATCH ?
            """
            var args: [DatabaseValueConvertible] = [sanitized]

            if let since {
                sql += " AND b.createdAt >= ?"
                args.append(since)
            }
            sql += " ORDER BY rank LIMIT ?"
            args.append(limit)

            return try Brief.fetchAll(db, sql: sql, arguments: StatementArguments(args))
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

            return try Self.attachMessages(to: sources, db: db)
        }
    }

    /// Evidence lookup by brief + service + conversation — used when only the LLM card ID is
    /// available in the UI, which doesn't match the UUID stored in BriefCardSource.briefCardId.
    func fetchSourcesWithMessages(briefID: Int64, service: String, conversationID: String) throws -> [(source: BriefCardSource, message: Message?)] {
        try database.dbQueue.read { db in
            guard let card = try BriefCardRecord
                .filter(Column("briefId") == briefID)
                .filter(Column("service") == service)
                .filter(Column("conversationId") == conversationID)
                .fetchOne(db) else { return [] }

            let sources = try BriefCardSource
                .filter(Column("briefCardId") == card.id)
                .order(Column("id").asc)
                .fetchAll(db)

            return try Self.attachMessages(to: sources, db: db)
        }
    }

    // Batch-fetches all messages referenced by `sources` in a single DB round-trip
    // and zips them back by row ID, avoiding the N+1 pattern.
    private static func attachMessages(
        to sources: [BriefCardSource],
        db: Database
    ) throws -> [(source: BriefCardSource, message: Message?)] {
        let rowIDs = sources.compactMap { $0.messageRowId }
        var messagesByRowID: [Int64: Message] = [:]
        if !rowIDs.isEmpty {
            let messages = try Message.fetchAll(db, keys: rowIDs)
            for msg in messages {
                if let id = msg.id { messagesByRowID[id] = msg }
            }
        }
        return sources.map { source in
            let message = source.messageRowId.flatMap { messagesByRowID[$0] }
            return (source: source, message: message)
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
