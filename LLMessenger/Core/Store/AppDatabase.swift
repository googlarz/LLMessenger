import GRDB
import Foundation

// Thread-safe: DatabaseQueue serializes all access internally.
final class AppDatabase: @unchecked Sendable {
    let dbQueue: DatabaseQueue
    /// On-disk path, if any — nil for the in-memory test store. Used by
    /// DataExporter to locate the live file for backup/restore.
    let path: String?

    /// Production store in ~/Library/Application Support/LLMessenger/.
    /// If the store fails to open or fails PRAGMA quick_check, it is moved
    /// aside (preserved for forensics) and a fresh store is created — the app
    /// must never crash-loop on a corrupt database. Messages re-fetch from
    /// their source services; only brief history is lost.
    static func production() throws -> AppDatabase {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMessenger")
        try FileManager.default.createDirectory(at: appSupport,
                                                withIntermediateDirectories: true,
                                                attributes: [FileAttributeKey.posixPermissions: 0o700])
        let dbPath = appSupport.appendingPathComponent("llmessenger.db").path

        do {
            let db = try AppDatabase(path: dbPath)
            try db.integrityCheck()
            return db
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.moveItem(
                    atPath: dbPath + suffix,
                    toPath: dbPath + ".corrupt-\(stamp)" + suffix)
            }
            NSLog("[AppDatabase] store unusable (%@) — moved aside as .corrupt-%d, recreating",
                  String(describing: error), stamp)
            return try AppDatabase(path: dbPath)
        }
    }

    /// Throws if SQLite's quick_check reports anything but "ok".
    func integrityCheck() throws {
        try dbQueue.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "no result"
            guard result == "ok" else {
                throw DatabaseError(resultCode: .SQLITE_CORRUPT,
                                    message: "quick_check failed: \(result)")
            }
        }
    }

    /// In-memory init for tests.
    init(inMemory: Bool) throws {
        precondition(inMemory)
        dbQueue = try DatabaseQueue()
        path = nil
        try migrate()
    }

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        self.path = path
        try? FileManager.default.setAttributes([FileAttributeKey.posixPermissions: 0o600], ofItemAtPath: path)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        // WARNING: erases all user data whenever migrations change during DEBUG builds.
        // Uncomment when you need a clean slate during development. Keep commented to preserve data.
        // #if DEBUG
        // migrator.eraseDatabaseOnSchemaChange = true
        // #endif
        migrator.registerMigration("v1_schema") { db in
            try db.create(table: "briefs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull()
                t.column("status", .text).notNull().defaults(to: "ready")
                t.column("services", .text).notNull()
                t.column("openingSummary", .text)
                t.column("notificationText", .text).notNull()
                t.column("episodicSummary", .text)
            }
            try db.create(table: "messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("briefId", .integer).references("briefs", onDelete: .setNull)
                t.column("service", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("sender", .text).notNull()
                t.column("text", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("isSent", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["service", "messageId"])
            }
            try db.create(table: "serviceConfig") { t in
                t.column("service", .text).primaryKey()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("pollIntervalMinutes", .integer).notNull().defaults(to: 30)
                t.column("fetchMode", .text).notNull().defaults(to: "count")
                t.column("fetchLimit", .integer).notNull().defaults(to: 50)
                t.column("privacyMode", .text).notNull().defaults(to: "on_demand")
            }
            try db.create(table: "serviceHealth") { t in
                t.column("service", .text).primaryKey()
                t.column("status", .text).notNull().defaults(to: "ok")
                t.column("lastCheck", .datetime)
                t.column("lastError", .text)
                t.column("retryAfter", .integer)
            }
        }
        migrator.registerMigration("v2_indexes") { db in
            try db.create(index: "messages_on_briefId", on: "messages", columns: ["briefId"])
            try db.create(index: "messages_on_timestamp", on: "messages", columns: ["timestamp"])
        }
        migrator.registerMigration("v3_conversation_name") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "conversationName", .text)
            }
        }
        migrator.registerMigration("v4_source_backed_briefs") { db in
            try db.create(table: "conversationState") { t in
                t.column("service", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("lastSeenMessageId", .text)
                t.column("lastSummarizedMessageId", .text)
                t.column("rollingSummary", .text)
                t.column("participants", .text)
                t.column("knownEntities", .text)
                t.column("unresolvedActions", .text)
                t.column("lastBriefCardId", .text)
                t.column("prioritySignals", .text)
                t.column("sourceMessageIds", .text)
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["service", "conversationId"])
            }

            try db.create(table: "briefCards") { t in
                t.column("id", .text).primaryKey()
                t.column("briefId", .integer).notNull().references("briefs", onDelete: .cascade)
                t.column("service", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("conversationTitle", .text)
                t.column("headline", .text).notNull()
                t.column("priority", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("actionItems", .text).notNull()
                t.column("callbackText", .text)
                t.column("sourceMessageIds", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "briefCardSources") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("briefCardId", .text).notNull().references("briefCards", onDelete: .cascade)
                t.column("messageRowId", .integer).references("messages", onDelete: .setNull)
                t.column("service", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("sourceRole", .text).notNull()
                t.column("quoteText", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "llmRuns") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("briefId", .integer).references("briefs", onDelete: .setNull)
                t.column("service", .text)
                t.column("conversationId", .text)
                t.column("backend", .text).notNull()
                t.column("model", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("completedAt", .datetime)
                t.column("status", .text).notNull()
                t.column("errorCategory", .text)
                t.column("promptHash", .text)
                t.column("responseHash", .text)
                t.column("inputTokenEstimate", .integer)
                t.column("outputTokenEstimate", .integer)
            }

            try db.create(index: "briefCards_on_briefId", on: "briefCards", columns: ["briefId"])
            try db.create(index: "briefCards_on_service_conversation", on: "briefCards", columns: ["service", "conversationId"])
            try db.create(index: "briefCardSources_on_card", on: "briefCardSources", columns: ["briefCardId"])
            try db.create(index: "llmRuns_on_briefId", on: "llmRuns", columns: ["briefId"])
        }
        migrator.registerMigration("v5_failed_services") { db in
            try db.alter(table: "briefs") { t in
                t.add(column: "failedServices", .text)
            }
        }
        migrator.registerMigration("v6_fts5_and_pinned") { db in
            // 1. Add pinned column to briefs (defaults to false)
            try db.alter(table: "briefs") { t in
                t.add(column: "pinned", .boolean).notNull().defaults(to: false)
            }

            // 2. FTS5 external-content table for messages
            try db.execute(sql: """
                CREATE VIRTUAL TABLE messages_fts USING fts5(
                    text, sender, conversationName,
                    content=messages, content_rowid=id
                )
            """)

            // Populate FTS5 from existing rows
            try db.execute(sql: """
                INSERT INTO messages_fts(rowid, text, sender, conversationName)
                SELECT id, text, sender, COALESCE(conversationName, '') FROM messages
            """)

            // Triggers to keep FTS5 in sync with messages
            try db.execute(sql: """
                CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO messages_fts(rowid, text, sender, conversationName)
                    VALUES (new.id, new.text, new.sender, COALESCE(new.conversationName, ''));
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, text, sender, conversationName)
                    VALUES ('delete', old.id, old.text, old.sender, COALESCE(old.conversationName, ''));
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, text, sender, conversationName)
                    VALUES ('delete', old.id, old.text, old.sender, COALESCE(old.conversationName, ''));
                    INSERT INTO messages_fts(rowid, text, sender, conversationName)
                    VALUES (new.id, new.text, new.sender, COALESCE(new.conversationName, ''));
                END
            """)

            // 3. FTS5 external-content table for briefs
            try db.execute(sql: """
                CREATE VIRTUAL TABLE briefs_fts USING fts5(
                    notificationText, openingSummary,
                    content=briefs, content_rowid=id
                )
            """)

            try db.execute(sql: """
                INSERT INTO briefs_fts(rowid, notificationText, openingSummary)
                SELECT id, notificationText, COALESCE(openingSummary, '') FROM briefs
            """)

            try db.execute(sql: """
                CREATE TRIGGER briefs_ai AFTER INSERT ON briefs BEGIN
                    INSERT INTO briefs_fts(rowid, notificationText, openingSummary)
                    VALUES (new.id, new.notificationText, COALESCE(new.openingSummary, ''));
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER briefs_ad AFTER DELETE ON briefs BEGIN
                    INSERT INTO briefs_fts(briefs_fts, rowid, notificationText, openingSummary)
                    VALUES ('delete', old.id, old.notificationText, COALESCE(old.openingSummary, ''));
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER briefs_au AFTER UPDATE ON briefs BEGIN
                    INSERT INTO briefs_fts(briefs_fts, rowid, notificationText, openingSummary)
                    VALUES ('delete', old.id, old.notificationText, COALESCE(old.openingSummary, ''));
                    INSERT INTO briefs_fts(rowid, notificationText, openingSummary)
                    VALUES (new.id, new.notificationText, COALESCE(new.openingSummary, ''));
                END
            """)
        }
        migrator.registerMigration("v7_window_start") { db in
            // windowStart records the beginning of the brief's fetch window.
            // NULL for hourly auto-poll briefs; set for on-demand summarizeLast() briefs.
            try db.alter(table: "briefs") { t in
                t.add(column: "windowStart", .datetime)
            }
        }
        migrator.registerMigration("v8_conversation_context_and_corrections") { db in
            try db.create(table: "conversationContexts") { t in
                t.column("service", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("label", .text).notNull().defaults(to: "")
                t.column("priorityHint", .text).notNull().defaults(to: "auto")
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["service", "conversationId"])
            }
            try db.create(table: "priorityCorrections") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("service", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("cardHeadline", .text).notNull()
                t.column("llmPriority", .text).notNull()
                t.column("userPriority", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "priorityCorrections_on_createdAt",
                          on: "priorityCorrections", columns: ["createdAt"])
        }
        migrator.registerMigration("v9_backfill_sent_messages") { db in
            // iMessageAdapter sets sender="Me" only when is_from_me=1, so this is safe:
            // pre-fix polls stored these rows with isSent=false. Repair them so user replies
            // get treated correctly by brief generation and recent-context queries.
            try db.execute(sql: """
                UPDATE messages SET isSent = 1
                WHERE service = 'imessage' AND sender = 'Me' AND isSent = 0
            """)
        }
        migrator.registerMigration("v10_contact_preferences") { db in
            try db.create(table: "contactPreferences") { t in
                t.column("displayName", .text).primaryKey()
                t.column("lastService", .text).notNull()
                t.column("lastUsedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v11_indexes") { db in
            try db.create(index: "messages_on_service_conversation", on: "messages", columns: ["service", "conversationId"])
            // Note: conversationState(service, conversationId) is the composite PK — GRDB creates an
            // autoindex for it, so no explicit index is needed here.
        }
        migrator.registerMigration("v12_schema_hardening") { db in
            // Hot query path: brief generation reads messages by service + time window
            try db.create(index: "messages_on_service_timestamp",
                          on: "messages",
                          columns: ["service", "timestamp"],
                          ifNotExists: true)

            // ORDER BY createdAt queries on briefs table
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS briefs_on_createdAt ON briefs(createdAt DESC)")

            // llmRuns analytics
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS llmRuns_on_startedAt ON llmRuns(startedAt DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS llmRuns_on_status ON llmRuns(status)")
        }
        migrator.registerMigration("v13_priority_rules") { db in
            try db.create(table: "priorityRules") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contactPattern", .text)
                t.column("keywordPattern", .text)
                t.column("service", .text)
                t.column("setPriority", .text)
                t.column("suppress", .boolean).notNull().defaults(to: false)
                t.column("alwaysNotify", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v14_tasks") { db in
            try db.create(table: "tasks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("briefCardId", .text).notNull().references("briefCards", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("completedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "tasks_on_briefCardId", on: "tasks", columns: ["briefCardId"])
            try db.create(index: "tasks_on_completedAt", on: "tasks", columns: ["completedAt"])
        }
        migrator.registerMigration("v15_archive_snooze") { db in
            try db.alter(table: "briefs") { t in
                t.add(column: "archivedAt", .datetime)
                t.add(column: "snoozedUntil", .datetime)
            }
        }
        // ServiceConfig gained `pollIntervalSeconds` (per-service poll interval
        // feature) without a matching migration — every serviceConfig INSERT
        // failed with "no column named pollIntervalSeconds". 900s mirrors the
        // model's default.
        migrator.registerMigration("v16_poll_interval_seconds") { db in
            try db.alter(table: "serviceConfig") { t in
                t.add(column: "pollIntervalSeconds", .integer).notNull().defaults(to: 900)
            }
        }
        // The needs-reply query (WHERE priority='high' ORDER BY createdAt DESC)
        // full-scanned an unboundedly growing table on every sidebar refresh.
        migrator.registerMigration("v17_briefcards_priority_index") { db in
            try db.create(index: "briefCards_on_priority_createdAt",
                          on: "briefCards", columns: ["priority", "createdAt"])
        }
        migrator.registerMigration("v18_realtime_and_rules_v2") { db in
            // Real-time triage decisions: every triage event is persisted so the
            // Desk can explain why you were or weren't interrupted.
            try db.create(table: "triageEvents") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("service", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("priority", .text).notNull()          // "high" | "medium" | "low"
                t.column("needsReply", .boolean).notNull()
                t.column("reason", .text).notNull()            // LLM-produced explanation
                t.column("triggeredBy", .text).notNull()       // "rule" | "llm"
                t.column("notified", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "triageEvents_on_service_conversation",
                          on: "triageEvents", columns: ["service", "conversationId"])
            try db.create(index: "triageEvents_on_createdAt",
                          on: "triageEvents", columns: ["createdAt"])

            // Priority rules v2: quiet hours per rule.
            // NULL means no quiet window. Stored as "HH:mm" strings (e.g. "22:00").
            try db.alter(table: "priorityRules") { t in
                t.add(column: "quietStart", .text)
                t.add(column: "quietEnd", .text)
            }
        }

        migrator.registerMigration("v19_context_v2") { db in
            try db.alter(table: "conversationContexts") { t in
                t.add(column: "relationship", .text)
                t.add(column: "importantTopics", .text)   // JSON array string
                t.add(column: "noiseTopics", .text)        // JSON array string
                t.add(column: "keySenders", .text)         // JSON array string
                t.add(column: "contextNote", .text)
                t.add(column: "responseExpectation", .text)
                t.add(column: "privacyOverride", .text)    // "local_only" | "never_draft" | nil
            }
        }
        migrator.registerMigration("v20_context_aliases") { db in
            try db.alter(table: "conversationContexts") { t in
                t.add(column: "aliases", .text)   // JSON array string
            }
        }
        migrator.registerMigration("v21_conversation_tone") { db in
            try db.alter(table: "conversationContexts") { t in
                t.add(column: "tone", .text)
            }
        }
        migrator.registerMigration("v22_agent") { db in
            try db.create(table: "agentActions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()          // "reply" | "follow_up" | "calendar_hold" | "rsvp" | "ack"
                t.column("service", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("conversationName", .text).notNull()
                t.column("title", .text).notNull()          // short label for the queue row
                t.column("payload", .text).notNull()        // JSON: drafted text / event details
                t.column("reasoning", .text).notNull()      // why the agent proposed this
                t.column("confidence", .double).notNull().defaults(to: 0.5)
                t.column("riskLevel", .text).notNull().defaults(to: "normal")  // "low" | "normal" | "high"
                t.column("status", .text).notNull().defaults(to: "pending")    // pending|approved|executing|done|failed|skipped
                t.column("createdAt", .datetime).notNull()
                t.column("resolvedAt", .datetime)
            }
            try db.create(index: "agentActions_on_status_created", on: "agentActions", columns: ["status", "createdAt"])
            try db.create(table: "commitments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("direction", .text).notNull()      // "i_owe" | "they_owe"
                t.column("service", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("conversationName", .text).notNull()
                t.column("what", .text).notNull()
                t.column("dueAt", .datetime)
                t.column("evidenceMessageId", .text)
                t.column("status", .text).notNull().defaults(to: "open")  // open|fulfilled|dropped
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "actionAudit") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("actionKind", .text).notNull()
                t.column("service", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("detail", .text).notNull()         // what was sent/done
                t.column("trigger", .text).notNull()        // "approved" | "delegated"
                t.column("createdAt", .datetime).notNull()
            }
            try db.alter(table: "conversationContexts") { t in
                t.add(column: "delegation", .text)          // JSON array of auto-approved kinds; nil = none (P2 uses it)
            }
        }
        migrator.registerMigration("v23_delegation_scheduled") { db in
            // P2: armed delegated auto-sends. status "scheduled" + fire time.
            try db.alter(table: "agentActions") { t in
                t.add(column: "scheduledAt", .datetime)
            }
        }
        migrator.registerMigration("v24_commitment_link") { db in
            // P3: link a follow_up action to the commitment that produced it, so the
            // engine proposes at most one pending follow-up per commitment.
            try db.alter(table: "agentActions") { t in
                t.add(column: "commitmentId", .integer)
            }
        }
        migrator.registerMigration("v25_agent_maybe") { db in
            // "Maybe" surface: the agent flags a proposal it is unsure actually needs action.
            // NOT NULL + default false so every existing row reads as a definite (non-maybe) item.
            try db.alter(table: "agentActions") { t in
                t.add(column: "isMaybe", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v26_agent_schedule_metadata") { db in
            // Scheduled rows can come from either a user-staged approve or delegated auto-send.
            // Persisting that origin lets restart recovery route the send through the right gate.
            try db.alter(table: "agentActions") { t in
                t.add(column: "scheduledKind", .text)
                t.add(column: "scheduledWindow", .double)
            }
            try db.execute(
                sql: """
                UPDATE agentActions
                SET scheduledKind = ?, scheduledWindow = ?
                WHERE status = ? AND scheduledAt IS NOT NULL
                """,
                arguments: [
                    AgentActionScheduleKind.delegated.rawValue,
                    AgentAction.delegatedUndoWindow,
                    AgentActionStatus.scheduled.rawValue
                ])
        }
        migrator.registerMigration("v27_large_inbox_indexes") { db in
            try db.create(index: "messages_on_isSent_timestamp",
                          on: "messages", columns: ["isSent", "timestamp"],
                          ifNotExists: true)
            try db.create(index: "messages_on_service_conversation_timestamp",
                          on: "messages", columns: ["service", "conversationId", "timestamp"],
                          ifNotExists: true)
            try db.create(index: "commitments_on_status_createdAt",
                          on: "commitments", columns: ["status", "createdAt"],
                          ifNotExists: true)
            try db.create(index: "agentActions_on_status_scheduledAt",
                          on: "agentActions", columns: ["status", "scheduledAt"],
                          ifNotExists: true)
        }
        migrator.registerMigration("v28_brief_card_actionability") { db in
            try db.alter(table: "briefCards") { t in
                t.add(column: "needsReply", .boolean).notNull().defaults(to: false)
                t.add(column: "reason", .text)
                t.add(column: "grounding", .text).notNull().defaults(to: "direct")
            }
        }
        migrator.registerMigration("v29_compression_retry") { db in
            // Replaces the episodicSummary == "" permanent-failure sentinel with a
            // retryable timestamp — a transient compression failure (Ollama restart,
            // LLM timeout) should not permanently block that brief's episodic memory.
            try db.alter(table: "briefs") { t in
                t.add(column: "compressionFailedAt", .datetime)
            }
            // Existing "" sentinels become nil (uncompressed, eligible for retry)
            // rather than staying permanently stuck.
            try db.execute(sql: "UPDATE briefs SET episodicSummary = NULL WHERE episodicSummary = ''")
        }
        migrator.registerMigration("v30_durable_brief_jobs") { db in
            try db.create(table: "briefJobs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("status", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("startedAt", .datetime)
                t.column("completedAt", .datetime)
                t.column("attemptCount", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
            }

            try db.create(table: "briefJobMessages") { t in
                t.column("jobId", .integer).notNull().references("briefJobs", onDelete: .cascade)
                t.column("messageRowId", .integer).notNull().references("messages", onDelete: .cascade)
                t.column("status", .text).notNull().defaults(to: BriefJobMessageStatus.pending.rawValue)
                t.column("completedAt", .datetime)
                t.column("briefId", .integer).references("briefs", onDelete: .setNull)
                t.primaryKey(["jobId", "messageRowId"])
            }

            try db.create(index: "briefJobs_on_status_createdAt",
                          on: "briefJobs", columns: ["status", "createdAt"])
            try db.create(index: "briefJobMessages_on_job_status",
                          on: "briefJobMessages", columns: ["jobId", "status"])
            try db.execute(sql: """
                CREATE UNIQUE INDEX briefJobMessages_on_pending_message
                ON briefJobMessages(messageRowId)
                WHERE status = 'pending'
            """)
        }
        migrator.registerMigration("v31_fair_brief_job_retries") { db in
            try db.alter(table: "briefJobs") { t in
                t.add(column: "nextAttemptAt", .datetime)
            }
            try db.create(
                index: "briefJobs_on_kind_status_nextAttemptAt_createdAt",
                on: "briefJobs",
                columns: ["kind", "status", "nextAttemptAt", "createdAt"]
            )
            try db.create(
                index: "messages_on_briefId_isSent_timestamp",
                on: "messages",
                columns: ["briefId", "isSent", "timestamp"]
            )
        }
        migrator.registerMigration("v32_brief_prompt_indexes") { db in
            try db.create(
                index: "messages_on_briefId_isSent_service_timestamp",
                on: "messages",
                columns: ["briefId", "isSent", "service", "timestamp"]
            )
            try db.create(
                index: "briefCards_on_service_conversation_createdAt",
                on: "briefCards",
                columns: ["service", "conversationId", "createdAt"]
            )
        }
        migrator.registerMigration("v33_triage_message_identity") { db in
            try db.alter(table: "triageEvents") { table in
                table.add(column: "messageId", .text)
            }
            try db.create(
                index: "triageEvents_on_service_messageId",
                on: "triageEvents",
                columns: ["service", "messageId"],
                unique: true
            )
        }
        migrator.registerMigration("v34_llm_run_telemetry") { db in
            try db.alter(table: "llmRuns") { table in
                table.add(column: "purpose", .text).notNull().defaults(to: "unspecified")
                table.add(column: "durationMs", .integer)
                table.add(column: "requestedMaxTokens", .integer)
                table.add(column: "wasTruncated", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "llmRuns_on_purpose", on: "llmRuns", columns: ["purpose"])
        }
        migrator.registerMigration("v35_canonical_brief_cards") { db in
            try db.alter(table: "briefCards") { table in
                table.add(column: "logicalId", .text)
                table.add(column: "position", .integer).notNull().defaults(to: 0)
                table.add(column: "messageCount", .integer).notNull().defaults(to: 0)
                table.add(column: "threadCount", .integer).notNull().defaults(to: 0)
                table.add(column: "peopleCount", .integer).notNull().defaults(to: 0)
                table.add(column: "quotes", .text).notNull().defaults(to: "[]")
                table.add(column: "collapsed", .boolean).notNull().defaults(to: false)
            }
            try db.create(
                index: "briefCards_on_briefId_position",
                on: "briefCards",
                columns: ["briefId", "position"]
            )

            try Self.backfillCanonicalBriefCards(in: db)
        }
        try migrator.migrate(dbQueue)

        // A process cannot still own a running job after this database has been
        // reopened. Put interrupted work back in the queue for immediate replay.
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE briefJobs SET status = ?, updatedAt = ?, nextAttemptAt = NULL WHERE status = ?",
                arguments: [BriefJobStatus.queued.rawValue, Date(), BriefJobStatus.running.rawValue]
            )
        }
    }

    static func backfillCanonicalBriefCards(in db: Database) throws {
        let briefRows = try Row.fetchAll(db, sql: """
            SELECT id, openingSummary FROM briefs
            WHERE openingSummary IS NOT NULL AND openingSummary != ''
        """)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for briefRow in briefRows {
            guard let briefID = briefRow["id"] as Int64?,
                  let summary = briefRow["openingSummary"] as String?,
                  let parsed = BriefJSON.decodeLenient(from: summary) else { continue }
            let records = try BriefCardRecord
                .filter(Column("briefId") == briefID)
                .order(Column("createdAt").asc)
                .fetchAll(db)
            var unused = records
            for (position, card) in parsed.cards.enumerated() {
                let sourceSet = Set(card.sourceMessageIds)
                guard let matchIndex = unused.firstIndex(where: { record in
                    guard record.service == card.service,
                          record.conversationId == card.conversationId else { return false }
                    guard let data = record.sourceMessageIds.data(using: .utf8),
                          let ids = try? decoder.decode([String].self, from: data) else { return true }
                    return Set(ids) == sourceSet
                }) else { continue }
                let record = unused.remove(at: matchIndex)
                let quotesData = try encoder.encode(card.quotes)
                let quotesJSON = String(data: quotesData, encoding: .utf8) ?? "[]"
                try db.execute(sql: """
                    UPDATE briefCards
                    SET logicalId = ?, position = ?, messageCount = ?, threadCount = ?,
                        peopleCount = ?, quotes = ?, collapsed = ?
                    WHERE id = ?
                """, arguments: [
                    card.id, position, card.counts.messages, card.counts.threads,
                    card.counts.people, quotesJSON, card.collapsed, record.id
                ])
            }
        }
    }
}
