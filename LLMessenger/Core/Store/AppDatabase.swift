import GRDB
import Foundation

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
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
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
        try migrator.migrate(dbQueue)
    }
}
