// LLMessengerTests/SystemInvariantTests.swift
// Layer 2: Mathematical invariants — properties that must hold after ANY successful pipeline run.
// Each test encodes a structural guarantee, not a specific scenario.
import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class SystemInvariantTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    /// Inserts `messageIds` for one service, wires a DynamicMockLLMClient, runs the engine.
    private func runPipeline(db: AppDatabase,
                             service: String,
                             convId: String,
                             messageIds: [String]) async throws -> Int64? {
        for (i, mid) in messageIds.enumerated() {
            try await db.dbQueue.write { d in
                var m = Message(briefId: nil, service: service,
                                conversationId: convId, conversationName: nil,
                                messageId: mid, sender: "Sender",
                                text: "Msg \(i)",
                                timestamp: Date().addingTimeInterval(Double(i)),
                                isSent: false)
                try m.insert(d)
            }
        }
        let mock = DynamicMockLLMClient()
        mock.specs[service] = .init(convId: convId, messageIds: messageIds)
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        return try await engine.processNewMessages()
    }

    // MARK: - Invariant 1: Every card's conversationId has a backing attached message

    func testCardConversationIdExistsInAttachedMessages() async throws {
        let db = try makeDB()
        let rawId = try await runPipeline(db: db, service: "signal", convId: "alice-conv",
                                         messageIds: ["m1", "m2"])
        let briefId = try XCTUnwrap(rawId, "Pipeline must produce a brief for this invariant to be testable")

        let cards = try BriefRepository(database: db).fetchBriefCards(briefID: briefId)
        let messages = try await db.dbQueue.read { d in
            try Message.filter(Column("briefId") == briefId).fetchAll(d)
        }

        let msgConvIds = Set(messages.map(\.conversationId))
        for card in cards {
            XCTAssertTrue(msgConvIds.contains(card.conversationId),
                          "Invariant: card.conversationId '\(card.conversationId)' has no attached message")
        }
    }

    // MARK: - Invariant 2: Every card's service matches the service of attached messages

    func testCardServiceMatchesAttachedMessageService() async throws {
        let db = try makeDB()
        let rawId = try await runPipeline(db: db, service: "signal", convId: "s-conv",
                                         messageIds: ["sig-m1"])
        let briefId = try XCTUnwrap(rawId)

        let cards = try BriefRepository(database: db).fetchBriefCards(briefID: briefId)
        let messages = try await db.dbQueue.read { d in
            try Message.filter(Column("briefId") == briefId).fetchAll(d)
        }

        let msgServices = Set(messages.map(\.service))
        for card in cards {
            XCTAssertTrue(msgServices.contains(card.service),
                          "Invariant: card.service '\(card.service)' not in message services \(msgServices)")
        }
    }

    // MARK: - Invariant 3: Every sourceMessageId in every card resolves to a stored message

    func testSourceMessageIdsAllResolveToStoredMessages() async throws {
        let db = try makeDB()
        let rawId = try await runPipeline(db: db, service: "signal", convId: "s-conv",
                                         messageIds: ["m1", "m2", "m3"])
        let briefId = try XCTUnwrap(rawId)

        let cards = try BriefRepository(database: db).fetchBriefCards(briefID: briefId)
        let allMessages = try await db.dbQueue.read { d in try Message.fetchAll(d) }
        let allMessageIds = Set(allMessages.map(\.messageId))

        for card in cards {
            let sourceIds = (try? JSONDecoder().decode([String].self,
                                                       from: Data(card.sourceMessageIds.utf8))) ?? []
            XCTAssertFalse(sourceIds.isEmpty,
                           "Invariant: card '\(card.id)' must have at least one sourceMessageId")
            for sid in sourceIds {
                XCTAssertTrue(allMessageIds.contains(sid),
                              "Invariant: sourceMessageId '\(sid)' not found in any stored message")
            }
        }
    }

    // MARK: - Invariant 4: After a successful run, input messages have their briefId set

    func testProcessedMessagesHaveBriefIdSetAfterRun() async throws {
        let db = try makeDB()
        let rawId = try await runPipeline(db: db, service: "signal", convId: "s-conv",
                                         messageIds: ["m1", "m2"])
        let briefId = try XCTUnwrap(rawId)

        let messages = try await db.dbQueue.read { d in try Message.fetchAll(d) }
        XCTAssertFalse(messages.isEmpty, "Pre-condition: messages were inserted")
        XCTAssertTrue(messages.allSatisfy { $0.briefId == briefId },
                      "Invariant: all messages must have briefId=\(briefId) after successful run")
    }

    // MARK: - Invariant 5: Brief.services contains exactly the services that produced cards

    func testBriefServicesMatchCardServices() async throws {
        let db = try makeDB()

        // Two-service run
        try await db.dbQueue.write { d in
            var m1 = Message(briefId: nil, service: "signal", conversationId: "s-conv",
                             conversationName: nil, messageId: "sig-m1",
                             sender: "A", text: "Hi", timestamp: Date(), isSent: false)
            try m1.insert(d)
            var m2 = Message(briefId: nil, service: "telegram", conversationId: "t-conv",
                             conversationName: nil, messageId: "tg-m1",
                             sender: "B", text: "Hey", timestamp: Date().addingTimeInterval(1),
                             isSent: false)
            try m2.insert(d)
        }

        let mock = DynamicMockLLMClient()
        mock.specs["signal"]   = .init(convId: "s-conv", messageIds: ["sig-m1"])
        mock.specs["telegram"] = .init(convId: "t-conv", messageIds: ["tg-m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let rawId = try await engine.processNewMessages()
        let briefId = try XCTUnwrap(rawId)

        let brief = try BriefRepository(database: db).fetchBrief(id: briefId)!
        let briefServices = (try? JSONDecoder().decode([String].self,
                                                       from: Data(brief.services.utf8))) ?? []

        let cards = try BriefRepository(database: db).fetchBriefCards(briefID: briefId)
        let cardServices = Set(cards.map(\.service))

        for svc in cardServices {
            XCTAssertTrue(briefServices.contains(svc),
                          "Invariant: card service '\(svc)' not recorded in brief.services '\(brief.services)'")
        }
        XCTAssertEqual(Set(briefServices), cardServices,
                       "Invariant: brief.services must match exactly the set of services that produced cards")
    }

    // MARK: - Invariant 6: A stored brief always has at least one card

    func testBriefIsNeverStoredWithZeroCards() async throws {
        let db = try makeDB()
        let rawId = try await runPipeline(db: db, service: "signal", convId: "s-conv",
                                         messageIds: ["m1"])
        let briefId = try XCTUnwrap(rawId)

        // Check the specific brief
        let cards = try BriefRepository(database: db).fetchBriefCards(briefID: briefId)
        XCTAssertGreaterThan(cards.count, 0,
                             "Invariant: brief \(briefId) must have at least one card")

        // Check the universal property: every brief in the DB has cards
        let allBriefs = try await db.dbQueue.read { d in try Brief.fetchAll(d) }
        for brief in allBriefs {
            let briefCards = try BriefRepository(database: db).fetchBriefCards(briefID: brief.id!)
            XCTAssertGreaterThan(briefCards.count, 0,
                                 "Invariant: brief \(brief.id!) stored with zero cards — impossible if engine is correct")
        }
    }
}
