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

struct BriefConversationKey: Hashable, Sendable {
    var service: String
    var conversationID: String
}

struct BriefPromptRequest {
    var service: String
    var conversationID: String
    var before: Date
    var since: Date
    var recentMessageLimit: Int

    var key: BriefConversationKey {
        BriefConversationKey(service: service, conversationID: conversationID)
    }
}

struct BriefPromptData {
    var contexts: [BriefConversationKey: ConversationContext]
    var states: [BriefConversationKey: ConversationState]
    var previousCards: [BriefConversationKey: BriefCardRecord]
    var recentMessages: [BriefConversationKey: [Message]]
}

struct BriefRepository: Sendable {
    let database: AppDatabase

    static let maximumBriefJobAttempts = 3
    private static let baseBriefJobRetryDelay: TimeInterval = 60
    private static let maximumBriefJobRetryDelay: TimeInterval = 3600

    static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        let exponent = max(0, min(attempt - 1, 10))
        return min(
            baseBriefJobRetryDelay * pow(2, Double(exponent)),
            maximumBriefJobRetryDelay
        )
    }

    func fetchUnattachedMessages(
        serviceIDs: Set<String>? = nil,
        limit: Int? = nil
    ) throws -> [Message] {
        // Exclude messages older than 7 days — they won't improve a current brief and
        // would silently bloat the LLM prompt on every cycle until attached or pruned.
        if let serviceIDs, serviceIDs.isEmpty {
            return []
        }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return try database.dbQueue.read { db in
            var request = Message
                .filter(Column("briefId") == nil)
                .filter(Column("isSent") == false)
                .filter(Column("timestamp") >= cutoff)
                .order(Column("timestamp").asc)
            if let serviceIDs {
                request = request.filter(serviceIDs.contains(Column("service")))
            }
            if let limit {
                request = request.limit(limit)
            }
            return try request.fetchAll(db)
        }
    }

    func fetchUnattachedMessages(service: String, since: Date, limit: Int) throws -> [Message] {
        try database.dbQueue.read { db in
            try Message
                .filter(Column("briefId") == nil)
                .filter(Column("isSent") == false)
                .filter(Column("service") == service)
                .filter(Column("timestamp") > since)
                .order(Column("timestamp").asc)
                .limit(max(1, limit))
                .fetchAll(db)
        }
    }

    // MARK: - Durable Brief Jobs

    /// Claims the oldest replayable automatic job, or snapshots `messages` into
    /// a new job. Messages arriving after this transaction belong to a later job.
    func claimAutomaticBriefJob(
        messages: [Message],
        now: Date = Date(),
        messageLimit: Int? = nil
    ) throws -> BriefJobSnapshot? {
        try database.dbQueue.write { db in
            let replayable = [
                BriefJobStatus.queued.rawValue,
                BriefJobStatus.partial.rawValue,
                BriefJobStatus.failed.rawValue
            ]
            let placeholders = replayable.map { _ in "?" }.joined(separator: ",")
            var job = try BriefJob.fetchOne(
                db,
                sql: """
                    SELECT * FROM briefJobs
                    WHERE kind = ? AND status IN (\(placeholders))
                      AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?)
                    ORDER BY createdAt ASC
                    LIMIT 1
                """,
                arguments: StatementArguments([BriefJobKind.automatic.rawValue] + replayable + [now])
            )

            if job == nil {
                let candidates = messages.filter { $0.id != nil && $0.briefId == nil && !$0.isSent }
                let candidateRowIDs = candidates.compactMap(\.id)
                let ownedRowIDs: Set<Int64>
                if candidateRowIDs.isEmpty {
                    ownedRowIDs = []
                } else {
                    let owned = try BriefJobMessage
                        .filter(Column("status") == BriefJobMessageStatus.pending.rawValue)
                        .filter(candidateRowIDs.contains(Column("messageRowId")))
                        .select(Column("messageRowId"))
                        .asRequest(of: Int64.self)
                        .fetchAll(db)
                    ownedRowIDs = Set(owned)
                }
                let snapshotMessages = candidates.filter { message in
                    guard let id = message.id else { return false }
                    return !ownedRowIDs.contains(id)
                }
                guard !snapshotMessages.isEmpty else { return nil }

                var newJob = BriefJob(
                    id: nil,
                    kind: BriefJobKind.automatic.rawValue,
                    status: BriefJobStatus.queued.rawValue,
                    createdAt: now,
                    updatedAt: now,
                    startedAt: nil,
                    completedAt: nil,
                    nextAttemptAt: nil,
                    attemptCount: 0,
                    lastError: nil
                )
                try newJob.insert(db)
                guard let jobID = newJob.id else {
                    throw DatabaseError(message: "claimAutomaticBriefJob: no rowid after insert")
                }
                for message in snapshotMessages {
                    guard let messageRowID = message.id else { continue }
                    let item = BriefJobMessage(
                        jobId: jobID,
                        messageRowId: messageRowID,
                        status: BriefJobMessageStatus.pending.rawValue,
                        completedAt: nil,
                        briefId: nil
                    )
                    try item.insert(db)
                }
                job = newJob
            }

            guard var claimed = job, let jobID = claimed.id else { return nil }
            var pendingSQL = """
                SELECT m.*
                FROM messages m
                JOIN briefJobMessages j ON j.messageRowId = m.id
                WHERE j.jobId = ? AND j.status = ? AND m.briefId IS NULL
                ORDER BY m.timestamp ASC
            """
            if let messageLimit {
                pendingSQL += " LIMIT \(max(1, messageLimit))"
            }
            let pendingMessages = try Message.fetchAll(
                db,
                sql: pendingSQL,
                arguments: [jobID, BriefJobMessageStatus.pending.rawValue]
            )

            if pendingMessages.isEmpty {
                try db.execute(sql: """
                    UPDATE briefJobs
                    SET status = ?, updatedAt = ?, completedAt = ?, lastError = NULL
                    WHERE id = ?
                """, arguments: [BriefJobStatus.succeeded.rawValue, now, now, jobID])
                return nil
            }

            claimed.status = BriefJobStatus.running.rawValue
            claimed.updatedAt = now
            claimed.startedAt = now
            claimed.completedAt = nil
            claimed.nextAttemptAt = nil
            claimed.attemptCount += 1
            claimed.lastError = nil
            try claimed.update(db)
            return BriefJobSnapshot(job: claimed, messages: pendingMessages)
        }
    }

    func fetchBriefJobs() throws -> [BriefJob] {
        try database.dbQueue.read { db in
            try BriefJob.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    func fetchBriefJobMessages(jobID: Int64) throws -> [BriefJobMessage] {
        try database.dbQueue.read { db in
            try BriefJobMessage
                .filter(Column("jobId") == jobID)
                .order(Column("messageRowId").asc)
                .fetchAll(db)
        }
    }

    func fetchBriefPipelineHealth() throws -> BriefPipelineHealth {
        try database.dbQueue.read { db in
            let failed = BriefJobStatus.failed.rawValue
            let partial = BriefJobStatus.partial.rawValue
            let deadLetter = BriefJobStatus.deadLetter.rawValue
            let automatic = BriefJobKind.automatic.rawValue
            let pending = BriefJobMessageStatus.pending.rawValue
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(CASE
                        WHEN j.status = ? OR (j.status = ? AND j.lastError IS NOT NULL) THEN 1
                        ELSE 0
                    END), 0) AS retryingJobCount,
                    COALESCE(SUM(CASE WHEN j.status = ? THEN 1 ELSE 0 END), 0) AS deadLetterJobCount,
                    (
                        SELECT COUNT(*)
                        FROM briefJobMessages jm
                        JOIN briefJobs pendingJob ON pendingJob.id = jm.jobId
                        WHERE pendingJob.kind = ?
                          AND jm.status = ?
                          AND (
                            pendingJob.status IN (?, ?)
                            OR (pendingJob.status = ? AND pendingJob.lastError IS NOT NULL)
                          )
                    ) AS pendingMessageCount,
                    (
                        SELECT lastError
                        FROM briefJobs recentJob
                        WHERE recentJob.kind = ?
                          AND recentJob.lastError IS NOT NULL
                          AND recentJob.status IN (?, ?, ?)
                        ORDER BY recentJob.updatedAt DESC
                        LIMIT 1
                    ) AS latestError
                FROM briefJobs j
                WHERE j.kind = ?
            """, arguments: [
                failed, partial, deadLetter,
                automatic, pending, failed, deadLetter, partial,
                automatic, failed, partial, deadLetter,
                automatic
            ])
            guard let row else { return .healthy }
            return BriefPipelineHealth(
                retryingJobCount: row["retryingJobCount"],
                deadLetterJobCount: row["deadLetterJobCount"],
                pendingMessageCount: row["pendingMessageCount"],
                latestError: row["latestError"]
            )
        }
    }

    /// Explicitly restores exhausted automatic work to the queue. Completed
    /// message rows remain completed; only pending rows are replayed.
    @discardableResult
    func retryDeadLetterBriefJobs(now: Date = Date()) throws -> Int {
        try database.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE briefJobs
                SET status = ?, updatedAt = ?, startedAt = NULL, completedAt = NULL,
                    nextAttemptAt = ?, attemptCount = 0, lastError = NULL
                WHERE kind = ? AND status = ?
            """, arguments: [
                BriefJobStatus.queued.rawValue,
                now,
                now,
                BriefJobKind.automatic.rawValue,
                BriefJobStatus.deadLetter.rawValue
            ])
            return db.changesCount
        }
    }

    func markBriefJobFailed(jobID: Int64, error: String, now: Date = Date()) throws {
        try database.dbQueue.write { db in
            let attemptCount = try Int.fetchOne(
                db,
                sql: "SELECT attemptCount FROM briefJobs WHERE id = ?",
                arguments: [jobID]
            ) ?? 0
            let status: BriefJobStatus = attemptCount >= Self.maximumBriefJobAttempts ? .deadLetter : .failed
            let nextAttemptAt = status == .deadLetter
                ? nil
                : now.addingTimeInterval(Self.retryDelay(afterAttempt: attemptCount))
            try db.execute(sql: """
                UPDATE briefJobs
                SET status = ?, updatedAt = ?, completedAt = ?, nextAttemptAt = ?, lastError = ?
                WHERE id = ?
            """, arguments: [
                status.rawValue,
                now,
                status == .deadLetter ? now : nil,
                nextAttemptAt,
                String(error.prefix(1000)),
                jobID
            ])
        }
    }

    @discardableResult
    func skipBriefJobMessages(jobID: Int64, messages: [Message], now: Date = Date()) throws -> BriefJobStatus {
        try database.dbQueue.write { db in
            let rowIDs = messages.compactMap(\.id)
            if !rowIDs.isEmpty {
                let placeholders = rowIDs.map { _ in "?" }.joined(separator: ",")
                var arguments: [DatabaseValueConvertible] = [
                    BriefJobMessageStatus.skipped.rawValue,
                    now,
                    jobID
                ]
                arguments.append(contentsOf: rowIDs)
                try db.execute(sql: """
                    UPDATE briefJobMessages
                    SET status = ?, completedAt = ?, briefId = NULL
                    WHERE jobId = ? AND status = 'pending'
                      AND messageRowId IN (\(placeholders))
                """, arguments: StatementArguments(arguments))
            }

            let pending = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM briefJobMessages WHERE jobId = ? AND status = ?
            """, arguments: [jobID, BriefJobMessageStatus.pending.rawValue]) ?? 0
            let status: BriefJobStatus = pending == 0 ? .succeeded : .running
            try db.execute(sql: """
                UPDATE briefJobs
                SET status = ?, updatedAt = ?, completedAt = ?, nextAttemptAt = NULL,
                    lastError = NULL
                WHERE id = ?
            """, arguments: [
                status.rawValue,
                now,
                status == .succeeded ? now : nil,
                jobID
            ])
            return status
        }
    }

    /// Completes the successful subset and leaves the remaining snapshot rows
    /// pending. This participates in the same transaction that stores the brief.
    static func completeBriefJob(
        jobID: Int64,
        messages: [Message],
        briefID: Int64,
        failedServices: Set<String>,
        now: Date = Date(),
        db: Database
    ) throws {
        let rowIDs = messages.compactMap(\.id)
        if !rowIDs.isEmpty {
            let placeholders = rowIDs.map { _ in "?" }.joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = [
                BriefJobMessageStatus.succeeded.rawValue, now, briefID, jobID
            ]
            arguments.append(contentsOf: rowIDs)
            try db.execute(sql: """
                UPDATE briefJobMessages
                SET status = ?, completedAt = ?, briefId = ?
                WHERE jobId = ? AND messageRowId IN (\(placeholders))
            """, arguments: StatementArguments(arguments))
        }

        let pending = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM briefJobMessages WHERE jobId = ? AND status = ?
        """, arguments: [jobID, BriefJobMessageStatus.pending.rawValue]) ?? 0
        let attemptCount = try Int.fetchOne(
            db,
            sql: "SELECT attemptCount FROM briefJobs WHERE id = ?",
            arguments: [jobID]
        ) ?? 0
        let exhausted = pending > 0
            && !failedServices.isEmpty
            && attemptCount >= Self.maximumBriefJobAttempts
        let status: BriefJobStatus
        if pending == 0 {
            status = .succeeded
        } else if exhausted {
            status = .deadLetter
        } else {
            status = .partial
        }
        let failureText = failedServices.isEmpty ? nil : failedServices.sorted().joined(separator: ", ")
        let nextAttemptAt = pending > 0 && !failedServices.isEmpty && !exhausted
            ? now.addingTimeInterval(Self.retryDelay(afterAttempt: attemptCount))
            : nil
        try db.execute(sql: """
            UPDATE briefJobs
            SET status = ?, updatedAt = ?, completedAt = ?, nextAttemptAt = ?, lastError = ?
            WHERE id = ?
        """, arguments: [
            status.rawValue,
            now,
            status == .succeeded || status == .deadLetter ? now : nil,
            nextAttemptAt,
            failureText,
            jobID
        ])
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

    /// Backoff window before a failed compression is retried, so a stuck local
    /// model doesn't get hammered every brief cycle.
    static let compressionRetryBackoff: TimeInterval = 6 * 3600

    // Returns the oldest uncompressed brief so compression runs oldest-first,
    // preventing new briefs from starving older ones of episodic summaries.
    // Briefs that failed compression within the backoff window are excluded;
    // once the window elapses they become eligible again (unlike the old
    // episodicSummary == "" sentinel, which blocked retry forever).
    func fetchOldestUncompressedBrief(now: Date = Date()) throws -> Brief? {
        let retryAfter = now.addingTimeInterval(-Self.compressionRetryBackoff)
        return try database.dbQueue.read { db in
            try Brief
                .filter(Column("episodicSummary") == nil)
                .filter(sql: "compressionFailedAt IS NULL OR compressionFailedAt < ?", arguments: [retryAfter])
                .order(Column("createdAt").asc)
                .fetchOne(db)
        }
    }

    // Writes episodicSummary for a brief on successful compression, clearing
    // any prior failure mark.
    func setEpisodicSummary(briefID: Int64, summary: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefs SET episodicSummary = ?, compressionFailedAt = NULL WHERE id = ?",
                arguments: [summary, briefID]
            )
        }
    }

    /// Marks a brief's compression attempt as failed so it is retried after
    /// `compressionRetryBackoff` instead of every cycle or never again.
    func markCompressionFailed(briefID: Int64, at date: Date = Date()) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefs SET compressionFailedAt = ? WHERE id = ?",
                arguments: [date, briefID]
            )
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

    /// Loads all conversation metadata needed to build brief prompts with a
    /// fixed number of SQL statements. Automatic jobs cap requests at 500, well
    /// below SQLite's host-parameter limit on supported macOS releases.
    func fetchBriefPromptData(for requests: [BriefPromptRequest]) throws -> BriefPromptData {
        let requestsByKey = Dictionary(requests.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let uniqueRequests = Array(requestsByKey.values)
        guard !uniqueRequests.isEmpty else {
            return BriefPromptData(contexts: [:], states: [:], previousCards: [:], recentMessages: [:])
        }

        return try database.dbQueue.read { db in
            let pairValues = uniqueRequests.map { _ in "(?, ?)" }.joined(separator: ", ")
            let pairArguments = StatementArguments(uniqueRequests.flatMap { request -> [String] in
                [request.service, request.conversationID]
            })

            let contexts = try ConversationContext.fetchAll(
                db,
                sql: """
                    WITH requested(service, conversationId) AS (VALUES \(pairValues))
                    SELECT contexts.*
                    FROM conversationContexts contexts
                    JOIN requested USING (service, conversationId)
                    """,
                arguments: pairArguments
            )
            let states = try ConversationState.fetchAll(
                db,
                sql: """
                    WITH requested(service, conversationId) AS (VALUES \(pairValues))
                    SELECT states.*
                    FROM conversationState states
                    JOIN requested USING (service, conversationId)
                    """,
                arguments: pairArguments
            )
            let previousCards = try BriefCardRecord.fetchAll(
                db,
                sql: """
                    WITH requested(service, conversationId) AS (VALUES \(pairValues))
                    SELECT * FROM (
                        SELECT briefCards.*,
                               ROW_NUMBER() OVER (
                                   PARTITION BY service, conversationId
                                   ORDER BY createdAt DESC
                               ) AS promptRowNumber
                        FROM briefCards
                        JOIN requested USING (service, conversationId)
                    )
                    WHERE promptRowNumber = 1
                    """,
                arguments: pairArguments
            )

            let messageValues = uniqueRequests.map { _ in "(?, ?, ?, ?, ?)" }.joined(separator: ", ")
            var messageArguments: [DatabaseValueConvertible] = []
            for request in uniqueRequests {
                messageArguments.append(request.service)
                messageArguments.append(request.conversationID)
                messageArguments.append(request.before)
                messageArguments.append(request.since)
                messageArguments.append(max(1, request.recentMessageLimit))
            }
            let recentMessages = try Message.fetchAll(
                db,
                sql: """
                    WITH requested(service, conversationId, beforeDate, sinceDate, messageLimit) AS (
                        VALUES \(messageValues)
                    )
                    SELECT * FROM (
                        SELECT messages.*,
                               requested.messageLimit AS promptMessageLimit,
                               ROW_NUMBER() OVER (
                                   PARTITION BY messages.service, messages.conversationId
                                   ORDER BY messages.timestamp DESC
                               ) AS promptRowNumber
                        FROM messages
                        JOIN requested USING (service, conversationId)
                        WHERE messages.briefId IS NOT NULL
                          AND messages.timestamp < requested.beforeDate
                          AND messages.timestamp >= requested.sinceDate
                    )
                    WHERE promptRowNumber <= promptMessageLimit
                    ORDER BY service, conversationId, timestamp ASC
                    """,
                arguments: StatementArguments(messageArguments)
            )

            let recentByKey = Dictionary(grouping: recentMessages) {
                BriefConversationKey(service: $0.service, conversationID: $0.conversationId)
            }.mapValues { messages in
                let requestLimit = requestsByKey[
                    BriefConversationKey(service: messages[0].service, conversationID: messages[0].conversationId)
                ]?.recentMessageLimit ?? messages.count
                return Array(messages.suffix(max(1, requestLimit)))
            }

            return BriefPromptData(
                contexts: Dictionary(uniqueKeysWithValues: contexts.map {
                    (BriefConversationKey(service: $0.service, conversationID: $0.conversationId), $0)
                }),
                states: Dictionary(uniqueKeysWithValues: states.map {
                    (BriefConversationKey(service: $0.service, conversationID: $0.conversationId), $0)
                }),
                previousCards: Dictionary(uniqueKeysWithValues: previousCards.map {
                    (BriefConversationKey(service: $0.service, conversationID: $0.conversationId), $0)
                }),
                recentMessages: recentByKey
            )
        }
    }

    func fetchAllBriefs() throws -> [Brief] {
        try database.dbQueue.read { db in
            try Brief
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    func fetchRecentBriefs(limit: Int = 500, including selectedID: Int64? = nil) throws -> [Brief] {
        try database.dbQueue.read { db in
            var briefs = try Brief
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)

            if let selectedID,
               !briefs.contains(where: { $0.id == selectedID }),
               let selected = try Brief.fetchOne(db, key: selectedID) {
                briefs.append(selected)
                briefs.sort { $0.createdAt > $1.createdAt }
            }
            return briefs
        }
    }

    func fetchRecentBriefCards(service: String,
                               conversationId: String,
                               limit: Int = 5) throws -> [BriefCardRecord] {
        try database.dbQueue.read { db in
            try BriefCardRecord
                .filter(Column("service") == service)
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func fetchContactProfile(service: String, conversationId: String) throws -> ContactProfile? {
        try database.dbQueue.read { db in
            try ContactProfile
                .filter(Column("service") == service)
                .filter(Column("conversationId") == conversationId)
                .fetchOne(db)
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

    func upsertConversationStates(_ states: [ConversationState]) throws {
        guard !states.isEmpty else { return }
        try database.dbQueue.write { db in
            for state in states {
                try state.save(db)
            }
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

    func fetchConversationStates(
        for keys: [BriefConversationKey]
    ) throws -> [BriefConversationKey: ConversationState] {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return [:] }
        return try database.dbQueue.read { db in
            let values = uniqueKeys.map { _ in "(?, ?)" }.joined(separator: ", ")
            let arguments = StatementArguments(uniqueKeys.flatMap { [$0.service, $0.conversationID] })
            let states = try ConversationState.fetchAll(
                db,
                sql: """
                    WITH requested(service, conversationId) AS (VALUES \(values))
                    SELECT states.*
                    FROM conversationState states
                    JOIN requested USING (service, conversationId)
                    """,
                arguments: arguments
            )
            return Dictionary(uniqueKeysWithValues: states.map {
                (BriefConversationKey(service: $0.service, conversationID: $0.conversationId), $0)
            })
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
                .order(Column("position").asc, Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    func fetchBriefCards(briefIDs: [Int64]) throws -> [Int64: [BriefCard]] {
        guard !briefIDs.isEmpty else { return [:] }
        return try database.dbQueue.read { db in
            let records = try BriefCardRecord
                .filter(briefIDs.contains(Column("briefId")))
                .order(Column("briefId").asc, Column("position").asc, Column("createdAt").asc)
                .fetchAll(db)
            return Dictionary(grouping: records, by: \.briefId)
                .mapValues { $0.map(\.briefCard) }
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
                WHERE bc.needsReply = 1 OR bc.priority = 'high'
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
    func fetchSourcesWithMessages(
        briefID: Int64,
        service: String,
        conversationID: String,
        sourceMessageIds: [String] = []
    ) throws -> [(source: BriefCardSource, message: Message?)] {
        try database.dbQueue.read { db in
            let cards = try BriefCardRecord
                .filter(Column("briefId") == briefID)
                .filter(Column("service") == service)
                .filter(Column("conversationId") == conversationID)
                .order(Column("createdAt").asc)
                .fetchAll(db)
            guard let card = matchingCard(in: cards, sourceMessageIds: sourceMessageIds) else { return [] }

            let sources = try BriefCardSource
                .filter(Column("briefCardId") == card.id)
                .order(Column("id").asc)
                .fetchAll(db)

            return try Self.attachMessages(to: sources, db: db)
        }
    }

    private func matchingCard(
        in cards: [BriefCardRecord],
        sourceMessageIds: [String]
    ) -> BriefCardRecord? {
        let requested = sourceMessageIds.filter { !$0.isEmpty }
        guard !requested.isEmpty else { return cards.first }
        return cards.first { decodedStringArray($0.sourceMessageIds) == requested }
            ?? cards.first { Set(decodedStringArray($0.sourceMessageIds)) == Set(requested) }
            ?? cards.first
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

    func deleteConversationContext(service: String, conversationId: String) throws {
        _ = try database.dbQueue.write { db in
            try ConversationContext
                .filter(Column("service") == service && Column("conversationId") == conversationId)
                .deleteAll(db)
        }
    }

    func fetchAllConversationContexts() throws -> [ConversationContext] {
        try database.dbQueue.read { db in
            try ConversationContext.fetchAll(db)
        }
    }

    func fetchConversationContexts(for pairs: [(service: String, conversationId: String)]) throws -> [ConversationContext] {
        Array(try fetchConversationContexts(for: pairs.map {
            BriefConversationKey(service: $0.service, conversationID: $0.conversationId)
        }).values)
    }

    func fetchConversationContexts(
        for keys: [BriefConversationKey]
    ) throws -> [BriefConversationKey: ConversationContext] {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return [:] }
        return try database.dbQueue.read { db in
            let values = uniqueKeys.map { _ in "(?, ?)" }.joined(separator: ", ")
            let arguments = StatementArguments(uniqueKeys.flatMap { [$0.service, $0.conversationID] })
            let contexts = try ConversationContext.fetchAll(
                db,
                sql: """
                    WITH requested(service, conversationId) AS (VALUES \(values))
                    SELECT contexts.*
                    FROM conversationContexts contexts
                    JOIN requested USING (service, conversationId)
                    """,
                arguments: arguments
            )
            return Dictionary(uniqueKeysWithValues: contexts.map {
                (BriefConversationKey(service: $0.service, conversationID: $0.conversationId), $0)
            })
        }
    }

    // MARK: - Agent Actions

    /// The Act queue: pending proposals plus armed scheduled sends.
    func fetchPendingAgentActions() throws -> [AgentAction] {
        let active = [AgentActionStatus.pending.rawValue, AgentActionStatus.scheduled.rawValue]
        return try database.dbQueue.read { db in
            try AgentAction
                .filter(active.contains(Column("status")))
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// Arms an action behind an Undo window: status "scheduled" + fire time + schedule origin.
    @discardableResult
    func armAgentActionForAutoSend(id: Int64,
                                   scheduledAt: Date,
                                   kind: AgentActionScheduleKind = .delegated,
                                   undoWindow: TimeInterval = AgentAction.delegatedUndoWindow) throws -> Bool {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE agentActions
                SET status = ?, scheduledAt = ?, scheduledKind = ?, scheduledWindow = ?
                WHERE id = ? AND status = ?
                """,
                arguments: [
                    AgentActionStatus.scheduled.rawValue,
                    scheduledAt,
                    kind.rawValue,
                    undoWindow,
                    id,
                    AgentActionStatus.pending.rawValue
                ])
            return db.changesCount > 0
        }
    }

    /// Cancels an armed scheduled send (user tapped Undo): back to pending, no fire time.
    func disarmAgentAction(id: Int64) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE agentActions
                SET status = ?, scheduledAt = NULL, scheduledKind = NULL, scheduledWindow = NULL
                WHERE id = ? AND status = ?
                """,
                arguments: [
                    AgentActionStatus.pending.rawValue,
                    id,
                    AgentActionStatus.scheduled.rawValue
                ])
        }
    }

    /// Claims a still-scheduled action for execution. Returns false if Undo or another
    /// timer already changed the row, preventing duplicate sends from duplicate timers.
    func claimScheduledActionForExecution(id: Int64) throws -> Bool {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE agentActions
                SET status = ?, scheduledAt = NULL, scheduledKind = NULL, scheduledWindow = NULL
                WHERE id = ? AND status = ?
                """,
                arguments: [
                    AgentActionStatus.executing.rawValue,
                    id,
                    AgentActionStatus.scheduled.rawValue
                ])
            return db.changesCount > 0
        }
    }

    /// Inserts a proposed action (e.g. an on-demand follow-up from the Commitments surface).
    func insertAgentAction(_ action: AgentAction) throws {
        try database.dbQueue.write { db in
            var a = action
            try a.insert(db)
        }
    }

    func fetchAgentAction(id: Int64) throws -> AgentAction? {
        try database.dbQueue.read { db in
            try AgentAction.fetchOne(db, key: id)
        }
    }

    /// True if any message exists for this conversation (known recipient check).
    func conversationHasMessages(service: String, conversationId: String) throws -> Bool {
        try database.dbQueue.read { db in
            try Message
                .filter(Column("service") == service && Column("conversationId") == conversationId)
                .fetchCount(db) > 0
        }
    }

    func updateAgentActionStatus(id: Int64, status: AgentActionStatus, resolvedAt: Date?) throws {
        try database.dbQueue.write { db in
            if status == .scheduled {
                try db.execute(
                    sql: "UPDATE agentActions SET status = ?, resolvedAt = ? WHERE id = ?",
                    arguments: [status.rawValue, resolvedAt, id])
            } else {
                try db.execute(
                    sql: """
                    UPDATE agentActions
                    SET status = ?, resolvedAt = ?, scheduledAt = NULL,
                        scheduledKind = NULL, scheduledWindow = NULL
                    WHERE id = ?
                    """,
                    arguments: [status.rawValue, resolvedAt, id])
            }
        }
    }

    func updateAgentActionPayload(id: Int64, payload: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE agentActions SET payload = ? WHERE id = ?",
                arguments: [payload, id])
        }
    }

    // MARK: - Commitments

    /// All open commitments, newest first. Drives the Commitments ledger surface.
    func fetchOpenCommitments() throws -> [Commitment] {
        try database.dbQueue.read { db in
            try Commitment
                .filter(Column("status") == CommitmentStatus.open.rawValue)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// Open commitments for one conversation — used by the deriver to dedupe.
    func fetchOpenCommitments(service: String, conversationId: String) throws -> [Commitment] {
        try database.dbQueue.read { db in
            try Commitment
                .filter(Column("status") == CommitmentStatus.open.rawValue)
                .filter(Column("service") == service && Column("conversationId") == conversationId)
                .fetchAll(db)
        }
    }

    @discardableResult
    func insertCommitment(_ commitment: Commitment) throws -> Int64 {
        try database.dbQueue.write { db in
            var c = commitment
            try c.insert(db)
            guard let id = c.id else { throw DatabaseError(message: "insertCommitment: no rowid after insert") }
            return id
        }
    }

    func updateCommitmentStatus(id: Int64, status: CommitmentStatus) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE commitments SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id])
        }
    }

    func fetchCommitment(id: Int64) throws -> Commitment? {
        try database.dbQueue.read { db in
            try Commitment.filter(key: id).fetchOne(db)
        }
    }

    /// Pushes a commitment's due date out — used after a `they_owe` chase is sent, so the
    /// agent doesn't immediately re-propose the same nudge on the next tick.
    func bumpCommitmentDue(id: Int64, to date: Date) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE commitments SET dueAt = ? WHERE id = ?",
                arguments: [date, id])
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
                let task = BriefTask(briefCardId: card.id, text: item, completedAt: nil, createdAt: Date())
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

    func reopenTask(id: Int64) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tasks SET completedAt = NULL WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Retention pruning

    /// Deletes data that has already served its purpose and would otherwise grow
    /// forever: raw message text that has been folded into a brief (the brief's
    /// cards + episodic summary are the durable record), and pure audit/log rows.
    /// Never touches briefs themselves (visible digest history) or unattached
    /// messages (still waiting to be summarized). FTS5 triggers cascade the
    /// messages delete automatically. Returns the number of rows removed, for
    /// diagnostics.
    @discardableResult
    func pruneOldData(olderThan cutoff: Date) throws -> Int {
        try database.dbQueue.write { db in
            var deleted = 0
            try db.execute(sql: "DELETE FROM messages WHERE briefId IS NOT NULL AND timestamp < ?",
                           arguments: [cutoff])
            deleted += db.changesCount
            try db.execute(sql: "DELETE FROM triageEvents WHERE createdAt < ?", arguments: [cutoff])
            deleted += db.changesCount
            try db.execute(sql: "DELETE FROM actionAudit WHERE createdAt < ?", arguments: [cutoff])
            deleted += db.changesCount
            return deleted
        }
    }
}
