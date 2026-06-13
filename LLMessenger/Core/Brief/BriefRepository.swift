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
            try Self.attach(messages: messages, toBriefID: briefID, db: db)
        }
    }

    /// Participates in a caller-supplied write transaction.
    static func attach(messages: [Message], toBriefID briefID: Int64, db: Database) throws {
        for var msg in messages {
            msg.briefId = briefID
            try msg.update(db)
        }
    }

    func insertBrief(_ brief: Brief) throws -> Int64 {
        try database.dbQueue.write { db in
            try Self.insertBrief(brief, db: db)
        }
    }

    /// Participates in a caller-supplied write transaction.
    static func insertBrief(_ brief: Brief, db: Database) throws -> Int64 {
        var b = brief
        try b.insert(db)
        guard let id = b.id else { throw DatabaseError(message: "insertBrief: no rowid after insert") }
        return id
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
        // Collect all incoming message IDs up front.
        let incomingIDs = result.conversations.flatMap { $0.messages.map(\.id) }
        guard !incomingIDs.isEmpty else { return [] }

        // Single bulk read: fetch existing rows for this service matching the incoming IDs.
        // This replaces the per-message fetchOne inside the write transaction (N+1 → 1 read).
        // For large batches (>500 IDs) SQLite's bound-parameter limit requires chunking.
        let existingMessages: [Message]
        if incomingIDs.count <= 500 {
            let placeholders = incomingIDs.map { _ in "?" }.joined(separator: ",")
            existingMessages = try database.dbQueue.read { db in
                let sql = "SELECT * FROM messages WHERE service = ? AND messageId IN (\(placeholders))"
                let args = StatementArguments([service] + incomingIDs)
                return try Message.fetchAll(db, sql: sql, arguments: args)
            }
        } else {
            var all: [Message] = []
            for batchStart in stride(from: 0, to: incomingIDs.count, by: 500) {
                let batch = Array(incomingIDs[batchStart..<min(batchStart + 500, incomingIDs.count)])
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                let sql = "SELECT * FROM messages WHERE service = ? AND messageId IN (\(placeholders))"
                let args = StatementArguments([service] + batch)
                let fetched = try database.dbQueue.read { db in
                    try Message.fetchAll(db, sql: sql, arguments: args)
                }
                all.append(contentsOf: fetched)
            }
            existingMessages = all
        }
        // Map messageId → existing record for O(1) lookup in the write loop.
        let existingByID = Dictionary(existingMessages.map { ($0.messageId, $0) }, uniquingKeysWith: { a, _ in a })

        var stored: [Message] = []
        try database.dbQueue.write { db in
            for conv in result.conversations {
                for msg in conv.messages {
                    if let existing = existingByID[msg.id] {
                        // Already in DB — include it if unattached, same as before.
                        if existing.briefId == nil {
                            stored.append(existing)
                        }
                        continue
                    }
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

    func setArchived(briefID: Int64, archivedAt: Date?) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefs SET archivedAt = ? WHERE id = ?",
                arguments: [archivedAt, briefID]
            )
        }
    }

    func setSnoozed(briefID: Int64, snoozedUntil: Date?) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefs SET snoozedUntil = ? WHERE id = ?",
                arguments: [snoozedUntil, briefID]
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

    /// Inserts all cards in a single write transaction. Each card must have at least one source ID.
    func insertBriefCardsBatch(_ cards: [BriefCardRecord]) throws {
        try database.dbQueue.write { db in
            try Self.insertBriefCardsBatch(cards, db: db)
        }
    }

    /// Participates in a caller-supplied write transaction.
    static func insertBriefCardsBatch(_ cards: [BriefCardRecord], db: Database) throws {
        for card in cards {
            let sourceIDs = card.sourceMessageIds.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
                .map { $0.filter { !$0.isEmpty } } ?? []
            guard !sourceIDs.isEmpty else { throw BriefRepositoryError.briefCardMissingSources }
        }
        for card in cards {
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

    /// Returns the most recent high-priority card per conversation, across all briefs.
    /// Used by the "Needs Reply" triage view. Deduplicates by service+conversationId,
    /// keeping only the newest card per conversation so each thread appears once.
    func fetchRecentHighPriorityCards(limit: Int = 30) throws -> [(card: BriefCardRecord, briefCreatedAt: Date)] {
        try database.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bc.*, b.createdAt AS briefCreatedAt
                FROM briefCards bc
                JOIN briefs b ON bc.briefId = b.id
                WHERE bc.priority = 'high'
                ORDER BY bc.createdAt DESC
                LIMIT ?
            """, arguments: [limit])
            return rows.compactMap { row in
                // `as Date?` uses GRDB's typed subscript (value conversion).
                // A conditional `as?` cast on the untyped subscript always
                // failed against SQLite's string-stored dates, so this list
                // was permanently empty.
                guard let card = try? BriefCardRecord(row: row),
                      let briefCreatedAt = row["briefCreatedAt"] as Date? else { return nil }
                return (card: card, briefCreatedAt: briefCreatedAt)
            }
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

    /// Returns all cards for a single (service, conversationId) pair across all briefs,
    /// newest brief first. Used by ConversationTimelineView.
    func fetchConversationTimeline(service: String, conversationID: String) throws -> [(briefDate: Date, card: BriefCardRecord)] {
        try database.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bc.*, b.createdAt AS briefCreatedAt
                FROM briefCards bc
                JOIN briefs b ON bc.briefId = b.id
                WHERE bc.service = ? AND bc.conversationId = ?
                ORDER BY b.createdAt DESC
            """, arguments: [service, conversationID])
            return rows.compactMap { row in
                guard let card = try? BriefCardRecord(row: row),
                      let briefDate = row["briefCreatedAt"] as Date? else { return nil }
                return (briefDate: briefDate, card: card)
            }
        }
    }

    func insertBriefCardSources(_ sources: [BriefCardSource]) throws {
        try database.dbQueue.write { db in
            try Self.insertBriefCardSources(sources, db: db)
        }
    }

    /// Participates in a caller-supplied write transaction.
    static func insertBriefCardSources(_ sources: [BriefCardSource], db: Database) throws {
        for var source in sources {
            try source.insert(db)
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

    // MARK: - Conversation Context

    func fetchConversationContext(service: String, conversationId: String) throws -> ConversationContext? {
        try database.dbQueue.read { db in
            try ConversationContext.fetchOne(db, key: ["service": service, "conversationId": conversationId])
        }
    }

    func upsertConversationContext(_ context: ConversationContext) throws {
        try database.dbQueue.write { db in
            try context.save(db)
        }
    }

    func fetchAllConversationContexts() throws -> [ConversationContext] {
        try database.dbQueue.read { db in
            try ConversationContext.fetchAll(db)
        }
    }

    // MARK: - Agent Actions

    func fetchPendingAgentActions() throws -> [AgentAction] {
        try database.dbQueue.read { db in
            try AgentAction
                .filter(Column("status") == AgentActionStatus.pending.rawValue)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    func updateAgentActionStatus(id: Int64, status: AgentActionStatus, resolvedAt: Date?) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE agentActions SET status = ?, resolvedAt = ? WHERE id = ?",
                arguments: [status.rawValue, resolvedAt, id])
        }
    }

    func updateAgentActionPayload(id: Int64, payload: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE agentActions SET payload = ? WHERE id = ?",
                arguments: [payload, id])
        }
    }

    // MARK: - Priority Corrections

    func insertPriorityCorrection(_ correction: PriorityCorrection) throws {
        var c = correction
        try database.dbQueue.write { db in
            try c.insert(db)
        }
    }

    /// Returns the most recent corrections, newest first. Used to build few-shot prompt examples.
    func fetchRecentPriorityCorrections(limit: Int = 6) throws -> [PriorityCorrection] {
        try database.dbQueue.read { db in
            try PriorityCorrection
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    private func decodedStringArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return array.filter { !$0.isEmpty }
    }

    // MARK: - Contact preferences

    /// Returns the service the user last picked for this display name, or nil if never picked.
    /// Display name matched case-insensitively via lowercasing on read and write.
    func preferredService(for displayName: String) throws -> String? {
        let key = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return try database.dbQueue.read { db in
            try String.fetchOne(db,
                sql: "SELECT lastService FROM contactPreferences WHERE displayName = ?",
                arguments: [key])
        }
    }

    /// Records that the user picked `service` for `displayName`. Upserts on the display name PK.
    func recordContactPick(displayName: String, service: String) throws {
        let key = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, !service.isEmpty else { return }
        try database.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO contactPreferences (displayName, lastService, lastUsedAt)
                VALUES (?, ?, ?)
                ON CONFLICT(displayName) DO UPDATE SET
                    lastService = excluded.lastService,
                    lastUsedAt = excluded.lastUsedAt
            """, arguments: [key, service, Date()])
        }
    }

    // MARK: - Tasks

    /// Inserts Task rows for a batch of cards inside an existing write transaction.
    /// Only creates tasks for cards with priority "high" or "med" that have non-empty action items.
    static func insertTasksForCards(_ cards: [BriefCardRecord], db: Database) throws {
        let decoder = JSONDecoder()
        for card in cards where card.priority == "high" || card.priority == "med" {
            guard let data = card.actionItems.data(using: .utf8),
                  let items = try? decoder.decode([String].self, from: data) else { continue }
            for item in items where !item.isEmpty {
                var task = BriefTask(briefCardId: card.id, text: item, completedAt: nil, createdAt: Date())
                try task.insert(db)
            }
        }
    }

    func fetchPendingTasks() throws -> [BriefTask] {
        try database.dbQueue.read { db in
            try BriefTask
                .filter(Column("completedAt") == nil)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    func completeTask(id: Int64) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tasks SET completedAt = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }
}
