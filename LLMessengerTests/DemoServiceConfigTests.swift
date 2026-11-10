// LLMessengerTests/DemoServiceConfigTests.swift
//
// Entering and leaving the demo must leave the user's service settings exactly as
// they were (a service they switched off stays off, custom intervals stay), even
// across a relaunch in the middle of the demo, and no real polling may run while the
// sample data is on screen. Uses isolated defaults and databases only.

import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class DemoServiceConfigTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DemoServiceConfigTests-\(UUID().uuidString)")!
    }

    private func config(_ service: String, enabled: Bool, minutes: Int = 30, seconds: Int = 900,
                        mode: String = "time", limit: Int = 50, privacy: String = "on_demand") -> ServiceConfig {
        ServiceConfig(service: service, enabled: enabled, pollIntervalMinutes: minutes,
                      fetchMode: mode, fetchLimit: limit, privacyMode: privacy, pollIntervalSeconds: seconds)
    }

    /// A user who finished setup: Telegram deliberately off (it still has a session),
    /// custom intervals, no row at all for Slack.
    private func seedRealConfigs(_ db: AppDatabase) throws -> [ServiceConfig] {
        let rows = [
            config("imessage", enabled: true, minutes: 7, seconds: 420, privacy: "eager"),
            config("signal", enabled: true, minutes: 15, seconds: 600, mode: "count", limit: 120),
            config("telegram", enabled: false, minutes: 45, seconds: 2700),
            config("whatsapp", enabled: false),
        ]
        let settings = SettingsRepository(database: db)
        for row in rows { try settings.saveServiceConfig(row) }
        return rows.sorted { $0.service < $1.service }
    }

    private func storedConfigs(_ db: AppDatabase) throws -> [ServiceConfig] {
        try db.dbQueue.read { try ServiceConfig.order(Column("service")).fetchAll($0) }
    }

    private func assertSame(_ a: [ServiceConfig], _ b: [ServiceConfig], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.map(\.service), b.map(\.service), file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.enabled, y.enabled, "\(x.service) enabled", file: file, line: line)
            XCTAssertEqual(x.pollIntervalMinutes, y.pollIntervalMinutes, "\(x.service) minutes", file: file, line: line)
            XCTAssertEqual(x.pollIntervalSeconds, y.pollIntervalSeconds, "\(x.service) seconds", file: file, line: line)
            XCTAssertEqual(x.fetchMode, y.fetchMode, file: file, line: line)
            XCTAssertEqual(x.fetchLimit, y.fetchLimit, file: file, line: line)
            XCTAssertEqual(x.privacyMode, y.privacyMode, file: file, line: line)
        }
    }

    func testDemoRoundTripRestoresExactlyTheUsersConfigs() throws {
        let db = try AppDatabase(inMemory: true)
        let defaults = isolatedDefaults()
        let before = try seedRealConfigs(db)

        try DemoSeeder.seed(into: db, activateDemoMode: false, defaults: defaults)
        let during = try storedConfigs(db)
        XCTAssertEqual(during.count, 5, "every service has a stand-in row while the demo is on")
        XCTAssertTrue(during.allSatisfy { !$0.enabled }, "nothing is enabled during the demo")

        try DemoSeeder.wipe(from: db, defaults: defaults)

        assertSame(try storedConfigs(db), before)
        XCTAssertEqual(try storedConfigs(db).first { $0.service == "telegram" }?.enabled, false,
                       "a disabled Telegram stays disabled")
        XCTAssertNil(try storedConfigs(db).first { $0.service == "slack" },
                     "a service with no row gets no row")
        XCTAssertEqual(try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM demoServiceConfigSnapshot") }, 0,
                       "the snapshot is used up")
    }

    func testARelaunchBetweenEnterAndExitStillRestores() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = isolatedDefaults()
        let before: [ServiceConfig]
        do {
            let db = try AppDatabase(path: url.path)
            before = try seedRealConfigs(db)
            try DemoSeeder.seed(into: db, activateDemoMode: false, defaults: defaults)
        }
        // "Relaunch": a new database handle on the same file, nothing in memory.
        let relaunched = try AppDatabase(path: url.path)
        try DemoSeeder.wipe(from: relaunched, defaults: defaults)

        assertSame(try storedConfigs(relaunched), before)
    }

    func testSeedingTwiceDoesNotReplaceTheSnapshotWithTheStandIns() throws {
        let db = try AppDatabase(inMemory: true)
        let defaults = isolatedDefaults()
        let before = try seedRealConfigs(db)

        try DemoSeeder.seed(into: db, activateDemoMode: false, defaults: defaults)
        // A second seed over the first fails on duplicate sample messages; whatever it
        // does must neither re-snapshot the stand-ins nor restore the real configs early.
        _ = try? DemoSeeder.seed(into: db, activateDemoMode: false, defaults: defaults)
        XCTAssertTrue(try storedConfigs(db).allSatisfy { !$0.enabled }, "still the demo's stand-ins")
        try DemoSeeder.wipe(from: db, defaults: defaults)

        assertSame(try storedConfigs(db), before)
    }

    func testAnOldDemoWithoutASnapshotStillWipesToEmpty() throws {
        let db = try AppDatabase(inMemory: true)
        let defaults = isolatedDefaults()
        try DemoSeeder.seed(into: db, activateDemoMode: false, defaults: defaults)
        try db.dbQueue.write { try $0.execute(sql: "DELETE FROM demoServiceConfigSnapshot") }

        try DemoSeeder.wipe(from: db, defaults: defaults)

        XCTAssertTrue(try storedConfigs(db).isEmpty)
    }

    func testStartingTheDemoFromTheAppStopsRealPolling() async throws {
        let db = try AppDatabase(inMemory: true)
        _ = try seedRealConfigs(db)
        let state = AppState(database: db, llmClient: UnconfiguredLLMClient(), llmModel: "t", isLLMConfigured: false,
                             basePrompt: "", defaults: isolatedDefaults())
        let engine = PollEngine(database: db)
        let adapter = FakeMessengerAdapter(serviceID: "imessage")
        adapter.addMessage(convId: "real-chat", msgId: "m1")
        engine.register(adapter: adapter, config: config("imessage", enabled: true, privacy: "eager"))
        state.onDemoModeStarted = { engine.suspendAllForDemo() }

        state.startDemoMode(activateDemoMode: false)

        await engine.pollAll()
        try? await engine.pollNow(serviceID: "imessage")
        XCTAssertTrue(adapter.fetchConfigs.isEmpty, "no real fetch while the demo is on screen")
        let leaked = try await db.dbQueue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages WHERE conversationId = 'real-chat'")
        }
        XCTAssertEqual(leaked, 0)
    }
}
