// LLMessengerTests/DataExporterTests.swift
import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class DataExporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataExporterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func makeSourceDatabase(path: String) throws -> AppDatabase {
        let db = try AppDatabase(path: path)
        try db.dbQueue.write { d in
            var brief = Brief(createdAt: Date(), status: "ready", services: #"["signal"]"#,
                              openingSummary: "{}", notificationText: "x",
                              episodicSummary: "compressed memory")
            try brief.insert(d)
        }
        return db
    }

    func testWriteBackupCopiesBriefsAndSelectedDefaults() throws {
        let dbPath = tempDir.appendingPathComponent("source.db").path
        let db = try makeSourceDatabase(path: dbPath)

        let defaults = UserDefaults(suiteName: "DataExporterTests-\(UUID().uuidString)")!
        defaults.set(["a:1", "b:2"], forKey: "handledCardKeys")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set("should-not-export", forKey: "someUnrelatedKey")

        let backupURL = tempDir.appendingPathComponent("out.llmessengerbackup")
        try DataExporter.writeBackup(database: db, to: backupURL, defaults: defaults)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let readBack = try DatabaseQueue(path: backupURL.path)
        try readBack.read { d in
            let briefs = try Brief.fetchAll(d)
            XCTAssertEqual(briefs.count, 1)
            XCTAssertEqual(briefs.first?.episodicSummary, "compressed memory")

            let onboardingRow = try Row.fetchOne(d, sql:
                "SELECT value FROM exportedUserDefaults WHERE key = 'hasCompletedOnboarding'")
            XCTAssertNotNil(onboardingRow, "exported key must be present")

            let unrelatedRow = try Row.fetchOne(d, sql:
                "SELECT value FROM exportedUserDefaults WHERE key = 'someUnrelatedKey'")
            XCTAssertNil(unrelatedRow, "keys outside exportedDefaultsKeys must not be exported")
        }
    }

    func testRestoreReplacesLiveStoreAndKeepsBeforeRestoreCopy() throws {
        let sourceDBPath = tempDir.appendingPathComponent("source.db").path
        let sourceDB = try makeSourceDatabase(path: sourceDBPath)

        let backupURL = tempDir.appendingPathComponent("backup.llmessengerbackup")
        let exportDefaults = UserDefaults(suiteName: "DataExporterTests-export-\(UUID().uuidString)")!
        exportDefaults.set(true, forKey: "hasCompletedOnboarding")
        try DataExporter.writeBackup(database: sourceDB, to: backupURL, defaults: exportDefaults)

        // Simulate a live store with different (older) content at the "current" path.
        let liveDBPath = tempDir.appendingPathComponent("live.db").path
        let liveDB = try AppDatabase(path: liveDBPath)
        try liveDB.dbQueue.write { d in
            var oldBrief = Brief(createdAt: Date.distantPast, status: "ready", services: "[]",
                                 openingSummary: nil, notificationText: "old-live-data",
                                 episodicSummary: nil)
            try oldBrief.insert(d)
        }

        let importDefaults = UserDefaults(suiteName: "DataExporterTests-import-\(UUID().uuidString)")!
        XCTAssertNil(importDefaults.object(forKey: "hasCompletedOnboarding"))

        try DataExporter.restore(from: backupURL, toDatabasePath: liveDBPath, defaults: importDefaults)

        // The live path now contains the backup's data.
        let restored = try DatabaseQueue(path: liveDBPath)
        try restored.read { d in
            let briefs = try Brief.fetchAll(d)
            XCTAssertEqual(briefs.count, 1)
            XCTAssertEqual(briefs.first?.notificationText, "x")
        }

        // The old live data was preserved as a sidecar, not silently destroyed.
        let beforeRestorePath = liveDBPath + ".before-restore"
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeRestorePath))
        let preserved = try DatabaseQueue(path: beforeRestorePath)
        try preserved.read { d in
            let briefs = try Brief.fetchAll(d)
            XCTAssertEqual(briefs.first?.notificationText, "old-live-data")
        }

        // Exported defaults were applied.
        XCTAssertEqual(importDefaults.bool(forKey: "hasCompletedOnboarding"), true)
    }

    func testRestoreRejectsFileThatIsNotARecognizableBackup() throws {
        let bogus = tempDir.appendingPathComponent("not-a-backup.txt")
        try "plain text, not sqlite".write(to: bogus, atomically: true, encoding: .utf8)

        let liveDBPath = tempDir.appendingPathComponent("live2.db").path
        XCTAssertThrowsError(try DataExporter.restore(from: bogus, toDatabasePath: liveDBPath))
    }
}
