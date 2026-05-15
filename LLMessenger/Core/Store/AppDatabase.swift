import GRDB
import Foundation

// Thread-safe: DatabaseQueue serializes all access internally.
final class AppDatabase: @unchecked Sendable {
    let dbQueue: DatabaseQueue

    /// Production init — stores DB in ~/Library/Application Support/LLMessenger/
    convenience init() throws {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMessenger")
        try FileManager.default.createDirectory(at: appSupport,
                                                withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("llmessenger.db").path
        try self.init(path: dbPath)
    }

    /// In-memory init for tests.
    init(inMemory: Bool) throws {
        precondition(inMemory)
        dbQueue = try DatabaseQueue()
        try migrate()
    }

    private init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
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
        try migrator.migrate(dbQueue)
    }
}
