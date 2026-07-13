import Foundation
import GRDB
import XCTest
@testable import LLMessenger

final class ProductionReadinessPerformanceTests: XCTestCase {
    private let messageCount = 100_000

    func testLargeArchiveRepositoryQueriesStayWithinBudgets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMessengerPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("archive.sqlite")
        let database = try AppDatabase(path: databaseURL.path)
        let repository = BriefRepository(database: database)
        try seedArchive(database)

        let (pending, pendingDuration) = try timed {
            try repository.fetchUnattachedMessages(limit: 2_000)
        }
        XCTAssertEqual(pending.count, 2_000)
        XCTAssertLessThan(pendingDuration, 2.0, "Pending-message lookup exceeded the 2s production budget")

        let (servicePending, serviceDuration) = try timed {
            try repository.fetchUnattachedMessages(
                service: "signal",
                since: Date().addingTimeInterval(-8 * 24 * 3_600),
                limit: 500
            )
        }
        XCTAssertEqual(servicePending.count, 500)
        XCTAssertLessThan(serviceDuration, 2.0, "Service-scoped lookup exceeded the 2s production budget")

        let (searchResults, searchDuration) = try timed {
            try repository.searchMessages(query: "escalationmarker", limit: 50)
        }
        XCTAssertEqual(searchResults.count, 50)
        XCTAssertLessThan(searchDuration, 2.0, "FTS search exceeded the 2s production budget")

        try database.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let databaseBytes = try totalSize(ofFilesIn: directory)
        XCTAssertLessThan(
            databaseBytes,
            256 * 1_024 * 1_024,
            "A 100k-message archive should remain below the 256 MiB storage budget"
        )
        print(String(
            format: "PERF archive=100000 pending=%.3fs service=%.3fs search=%.3fs size=%.1fMiB",
            pendingDuration,
            serviceDuration,
            searchDuration,
            Double(databaseBytes) / Double(1_024 * 1_024)
        ))
    }

    func testPendingMessageQueriesUseCoveringFilterIndexes() throws {
        let database = try AppDatabase(inMemory: true)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3_600)

        let generalPlan = try queryPlan(
            database,
            sql: """
                SELECT * FROM messages
                WHERE briefId IS NULL AND isSent = 0 AND timestamp >= ?
                ORDER BY timestamp ASC LIMIT 2000
                """,
            arguments: [cutoff]
        )
        XCTAssertTrue(
            generalPlan.contains("messages_on_briefId_isSent_timestamp"),
            "Unexpected general pending-message plan: \(generalPlan)"
        )

        let servicePlan = try queryPlan(
            database,
            sql: """
                SELECT * FROM messages
                WHERE briefId IS NULL AND isSent = 0 AND service = ? AND timestamp > ?
                ORDER BY timestamp ASC LIMIT 500
                """,
            arguments: ["signal", cutoff]
        )
        XCTAssertTrue(
            servicePlan.contains("messages_on_briefId_isSent_service_timestamp"),
            "Unexpected service pending-message plan: \(servicePlan)"
        )
        XCTAssertFalse(generalPlan.contains("SCAN messages"))
        XCTAssertFalse(servicePlan.contains("SCAN messages"))
    }

    private func seedArchive(_ database: AppDatabase) throws {
        let now = Date()
        try database.dbQueue.write { db in
            var brief = Brief(
                createdAt: now,
                status: BriefStatus.ready.rawValue,
                services: #"["signal","telegram","imessage","slack"]"#,
                notificationText: "Performance fixture"
            )
            try brief.insert(db)
            let briefID = try XCTUnwrap(brief.id)

            let sql = """
                INSERT INTO messages
                    (briefId, service, conversationId, conversationName,
                     messageId, sender, text, timestamp, isSent)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                """
            let statement = try db.makeStatement(sql: sql)
            let services = ["signal", "telegram", "imessage", "slack"]
            for index in 0..<messageCount {
                let service = services[index % services.count]
                let isPending = index >= messageCount - 2_000
                let marker = index % 997 == 0 ? " escalationmarker" : ""
                try statement.execute(arguments: [
                    isPending ? nil : briefID,
                    service,
                    "conversation-\(index % 1_000)",
                    "Contact \(index % 1_000)",
                    "message-\(index)",
                    "Sender \(index % 20)",
                    "Realistic archived message \(index) with searchable content\(marker)",
                    now.addingTimeInterval(Double(index - messageCount))
                ])
            }
        }
    }

    private func timed<T>(_ operation: () throws -> T) rethrows -> (T, TimeInterval) {
        let start = CFAbsoluteTimeGetCurrent()
        let value = try operation()
        return (value, CFAbsoluteTimeGetCurrent() - start)
    }

    private func queryPlan(
        _ database: AppDatabase,
        sql: String,
        arguments: StatementArguments
    ) throws -> String {
        try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
                .map { (row: Row) -> String in row["detail"] }
                .joined(separator: "\n")
        }
    }

    private func totalSize(ofFilesIn directory: URL) throws -> Int64 {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        return try files.reduce(into: 0) { total, file in
            total += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }
}
