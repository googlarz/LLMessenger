// LLMessengerTests/DemoSeederTests.swift
//
// Demo Mode must satisfy every contract the real pipeline satisfies:
// parseable opening JSON, evidence rows that join back to messages,
// needs-reply triage, tasks, and a complete wipe on exit.

import XCTest
@testable import LLMessenger

@MainActor
final class DemoSeederTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DemoSeeder.demoFlagKey)
        super.tearDown()
    }

    func testSeedProducesTwoBriefsWithParseableJSON() throws {
        let db = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: db)

        let repo = BriefRepository(database: db)
        let briefs = try repo.fetchAllBriefs()
        XCTAssertEqual(briefs.count, 2, "Demo seeds a morning brief and a quieter evening brief")
        XCTAssertTrue(DemoSeeder.isActive)

        for brief in briefs {
            let summary = try XCTUnwrap(brief.openingSummary)
            let json = try JSONDecoder().decode(BriefJSON.self, from: Data(summary.utf8))
            XCTAssertFalse(json.cards.isEmpty, "Every demo brief must carry cards")
        }

        let newest = briefs.max(by: { $0.createdAt < $1.createdAt })!
        XCTAssertEqual(newest.briefStatus, .ready, "Morning brief arrives unread so the badge shows")
        let json = try JSONDecoder().decode(BriefJSON.self, from: Data(newest.openingSummary!.utf8))
        XCTAssertEqual(json.cards.filter { $0.priority == "high" }.count, 1,
                       "Exactly one card is urgent — the demo's focal point")
        XCTAssertEqual(json.cards.filter(\.needsReply).count, 3,
                       "Actionability is separate from urgency in the demo")
        XCTAssertEqual(Set(json.cards.map(\.service)).count, 4,
                       "Morning brief shows all four services")
    }

    func testEvidenceJoinsResolveForEveryCard() throws {
        let db = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: db)

        let repo = BriefRepository(database: db)
        let briefs = try repo.fetchAllBriefs()
        for brief in briefs {
            let cards = try repo.fetchBriefCards(briefID: brief.id!)
            XCTAssertFalse(cards.isEmpty)
            for card in cards {
                let sources = try repo.fetchSources(briefCardID: card.id)
                XCTAssertFalse(sources.isEmpty, "Card \(card.id) must have evidence")
                for source in sources {
                    XCTAssertNotNil(source.messageRowId,
                                    "Demo evidence must link to a real message row")
                }
            }
        }
    }

    func testNeedsReplyAndTasksSurface() throws {
        let db = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: db)

        let repo = BriefRepository(database: db)
        let needsReply = try repo.fetchRecentHighPriorityCards(limit: 30)
        XCTAssertEqual(needsReply.count, 3, "Reply-needed triage includes urgent and lightweight actionable cards")

        let tasks = try repo.fetchPendingTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertTrue(tasks.contains { $0.text.contains("cap table") })
    }

    func testServicesAreDisabledWhileDemoActive() throws {
        let db = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: db)

        let settings = SettingsRepository(database: db)
        for service in ["imessage", "signal", "telegram", "slack"] {
            let config = try XCTUnwrap(try settings.loadServiceConfig(for: service))
            XCTAssertFalse(config.enabled, "\(service) must stay quiet during the demo")
        }
    }

    func testDemoSeedsPersonalizationContext() throws {
        let db = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: db)

        let repo = BriefRepository(database: db)
        let investor = try XCTUnwrap(repo.fetchConversationContext(service: "signal", conversationId: "demo-meridian"))
        XCTAssertEqual(investor.label, "investor")
        XCTAssertEqual(investor.priorityHint, "high")
        XCTAssertEqual(investor.relationship, "lead investor")
        XCTAssertEqual(investor.importantTopicsList, ["fundraise", "data room", "partner meeting"])
        XCTAssertEqual(investor.responseExpectation, "same day")

        let lowSignal = try XCTUnwrap(repo.fetchConversationContext(service: "telegram", conversationId: "demo-sailing"))
        XCTAssertEqual(lowSignal.priorityHint, "low")
        XCTAssertEqual(lowSignal.noiseTopicsList, ["schedule announcements", "crew chatter"])
    }

    func testWipeRemovesEverything() throws {
        let db = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: db)
        try DemoSeeder.wipe(from: db)

        XCTAssertFalse(DemoSeeder.isActive)
        let repo = BriefRepository(database: db)
        XCTAssertTrue(try repo.fetchAllBriefs().isEmpty)
        XCTAssertTrue(try repo.fetchPendingTasks().isEmpty)
        let counts = try db.dbQueue.read { d in
            [
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM messages") ?? -1,
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM briefCards") ?? -1,
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM briefCardSources") ?? -1,
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM conversationContexts") ?? -1,
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM serviceConfig") ?? -1
            ]
        }
        XCTAssertEqual(counts, [0, 0, 0, 0, 0])
    }
}
