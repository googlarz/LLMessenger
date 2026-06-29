// LLMessengerTests/BriefRepositoryTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class BriefRepositoryTests: XCTestCase {

    func testFetchUnattachedMessagesReturnsOnlyNullBriefId() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            var brief = Brief(createdAt: Date(), status: "ready",
                              services: "[]", openingSummary: nil,
                              notificationText: "x", episodicSummary: nil)
            try brief.insert(db)
            let briefId = brief.id

            for (i, briefIdValue) in [(0, nil as Int64?), (1, nil), (2, briefId)] {
                var msg = Message(briefId: briefIdValue, service: "telegram",
                                  conversationId: "c\(i)", messageId: "m\(i)",
                                  sender: "Alice", text: "msg \(i)",
                                  timestamp: Date(), isSent: false)
                try msg.insert(db)
            }
        }

        let repo = BriefRepository(database: db)
        let unattached = try repo.fetchUnattachedMessages()
        XCTAssertEqual(unattached.count, 2)
        XCTAssertTrue(unattached.allSatisfy { $0.briefId == nil })
    }

    func testAttachMessagesToBrief() throws {
        let db = try AppDatabase(inMemory: true)
        var briefId: Int64 = 0
        try db.dbQueue.write { db in
            var brief = Brief(createdAt: Date(), status: "ready",
                              services: "[]", openingSummary: nil,
                              notificationText: "x", episodicSummary: nil)
            try brief.insert(db)
            briefId = brief.id!

            for i in 0..<3 {
                var msg = Message(briefId: nil, service: "telegram",
                                  conversationId: "c\(i)", messageId: "m\(i)",
                                  sender: "A", text: "t",
                                  timestamp: Date(), isSent: false)
                try msg.insert(db)
            }
        }

        let repo = BriefRepository(database: db)
        let messages = try repo.fetchUnattachedMessages()
        try repo.attach(messages: messages, toBriefID: briefId)

        let stillUnattached = try repo.fetchUnattachedMessages()
        XCTAssertEqual(stillUnattached.count, 0)
    }

    func testFetchLatestUncompressedBriefReturnsMostRecent() throws {
        let db = try AppDatabase(inMemory: true)
        var newerId: Int64 = 0
        try db.dbQueue.write { db in
            var old = Brief(createdAt: Date(timeIntervalSinceNow: -3600),
                            status: "idle", services: "[]",
                            openingSummary: "old", notificationText: "x",
                            episodicSummary: "already compressed")
            try old.insert(db)
            var newer = Brief(createdAt: Date(),
                              status: "ready", services: "[]",
                              openingSummary: "newer", notificationText: "x",
                              episodicSummary: nil)
            try newer.insert(db)
            newerId = newer.id!
        }

        let repo = BriefRepository(database: db)
        let latest = try repo.fetchOldestUncompressedBrief()
        XCTAssertEqual(latest?.id, newerId)
        XCTAssertNil(latest?.episodicSummary)
    }

    func testFetchLatestUncompressedBriefReturnsNilWhenAllCompressed() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            var b = Brief(createdAt: Date(), status: "idle", services: "[]",
                          openingSummary: nil, notificationText: "x",
                          episodicSummary: "compressed")
            try b.insert(db)
        }
        let repo = BriefRepository(database: db)
        XCTAssertNil(try repo.fetchOldestUncompressedBrief())
    }

    func testFetchUnreadCountReturnsOnlyReadyBriefs() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        _ = try repo.insertBrief(makeBrief(status: "ready"))
        _ = try repo.insertBrief(makeBrief(status: "open"))
        XCTAssertEqual(try repo.fetchUnreadCount(), 1)
    }

    func testMarkAsOpenChangesStatus() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let id = try repo.insertBrief(makeBrief(status: "ready"))
        try repo.markAsOpen(briefID: id)
        let fetched = try repo.fetchBrief(id: id)
        XCTAssertEqual(fetched?.status, "open")
    }

    func testFetchRecentBriefsHonorsLimitNewestFirst() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let base = Date(timeIntervalSinceReferenceDate: 1_000)

        try db.dbQueue.write { db in
            for i in 0..<5 {
                var brief = Brief(
                    createdAt: base.addingTimeInterval(TimeInterval(i)),
                    status: "ready",
                    services: "[]",
                    openingSummary: nil,
                    notificationText: "brief \(i)",
                    episodicSummary: nil
                )
                try brief.insert(db)
            }
        }

        let recent = try repo.fetchRecentBriefs(limit: 2)
        XCTAssertEqual(recent.map(\.notificationText), ["brief 4", "brief 3"])
    }

    func testFetchRecentBriefsIncludesSelectedOutsideLimit() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let base = Date(timeIntervalSinceReferenceDate: 2_000)
        var oldestID: Int64 = 0

        try db.dbQueue.write { db in
            for i in 0..<5 {
                var brief = Brief(
                    createdAt: base.addingTimeInterval(TimeInterval(i)),
                    status: "ready",
                    services: "[]",
                    openingSummary: nil,
                    notificationText: "brief \(i)",
                    episodicSummary: nil
                )
                try brief.insert(db)
                if i == 0 { oldestID = brief.id! }
            }
        }

        let recent = try repo.fetchRecentBriefs(limit: 2, including: oldestID)
        XCTAssertEqual(recent.map(\.notificationText), ["brief 4", "brief 3", "brief 0"])
    }

    private func makeBrief(status: String) -> Brief {
        Brief(id: nil, createdAt: Date(), status: status, services: "[]",
              openingSummary: nil, notificationText: "test", episodicSummary: nil)
    }

    func testRecentEpisodicSummariesReturnsMostRecentFirst() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            for i in 0..<5 {
                var b = Brief(createdAt: Date(timeIntervalSinceNow: TimeInterval(-i * 100)),
                              status: "idle", services: "[\"signal\"]",
                              openingSummary: nil, notificationText: "x",
                              episodicSummary: "summary \(i)")
                try b.insert(db)
            }
        }

        let repo = BriefRepository(database: db)
        let recent = try repo.recentEpisodicSummaries(service: "signal", limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent[0].summary, "summary 0")
        XCTAssertEqual(recent[1].summary, "summary 1")
        XCTAssertEqual(recent[2].summary, "summary 2")
    }

    func testUpsertAndFetchConversationState() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let first = ConversationState(
            service: "telegram",
            conversationId: "c1",
            lastSeenMessageId: "m1",
            lastSummarizedMessageId: nil,
            rollingSummary: "Initial summary",
            participants: #"["Joanna"]"#,
            knownEntities: nil,
            unresolvedActions: nil,
            lastBriefCardId: nil,
            prioritySignals: nil,
            sourceMessageIds: #"["m1"]"#,
            updatedAt: Date()
        )

        try repo.upsertConversationState(first)
        var updated = first
        updated.rollingSummary = "Updated summary"
        updated.lastSummarizedMessageId = "m2"
        try repo.upsertConversationState(updated)

        let fetched = try repo.fetchConversationState(service: "telegram", conversationID: "c1")
        XCTAssertEqual(fetched?.rollingSummary, "Updated summary")
        XCTAssertEqual(fetched?.lastSummarizedMessageId, "m2")
    }

    func testInsertBriefCardRequiresSourceMessageIds() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let briefID = try repo.insertBrief(makeBrief(status: "ready"))
        let card = BriefCardRecord(
            id: "card-1",
            briefId: briefID,
            service: "telegram",
            conversationId: "c1",
            conversationTitle: "Joanna",
            headline: "Joanna asked about timing.",
            priority: "high",
            summary: "Joanna asked when you will arrive.",
            actionItems: #"["Reply with ETA."]"#,
            callbackText: nil,
            sourceMessageIds: "[]",
            createdAt: Date()
        )

        XCTAssertThrowsError(try repo.insertBriefCard(card)) { error in
            XCTAssertTrue(error is BriefRepositoryError)
        }
    }

    func testInsertBriefCardAndSources() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let briefID = try repo.insertBrief(makeBrief(status: "ready"))
        var messageID: Int64 = 0
        try db.dbQueue.write { db in
            var msg = Message(
                briefId: briefID,
                service: "telegram",
                conversationId: "c1",
                conversationName: "Joanna",
                messageId: "m1",
                sender: "Joanna",
                text: "When are you arriving?",
                timestamp: Date(),
                isSent: false
            )
            try msg.insert(db)
            messageID = msg.id!
        }
        let card = BriefCardRecord(
            id: "card-1",
            briefId: briefID,
            service: "telegram",
            conversationId: "c1",
            conversationTitle: "Joanna",
            headline: "Joanna asked about timing.",
            priority: "high",
            summary: "Joanna asked when you will arrive.",
            actionItems: #"["Reply with ETA."]"#,
            callbackText: nil,
            sourceMessageIds: #"["m1"]"#,
            createdAt: Date()
        )
        let source = BriefCardSource(
            briefCardId: "card-1",
            messageRowId: messageID,
            service: "telegram",
            messageId: "m1",
            sourceRole: BriefCardSourceRole.newMessage.rawValue,
            quoteText: "When are you arriving?",
            createdAt: Date()
        )

        try repo.insertBriefCard(card)
        try repo.insertBriefCardSources([source])

        let cards = try repo.fetchBriefCards(briefID: briefID)
        let sources = try repo.fetchSources(briefCardID: "card-1")
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].sourceMessageIds, #"["m1"]"#)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].sourceRole, BriefCardSourceRole.newMessage.rawValue)
    }

    func testNeedsReplyCardsAreReturnedEvenWhenLowPriority() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let briefID = try repo.insertBrief(makeBrief(status: "ready"))
        let card = BriefCardRecord(
            id: "card-needs-reply",
            briefId: briefID,
            service: "imessage",
            conversationId: "dad",
            conversationTitle: "Dad",
            headline: "Dad asks if 1pm works",
            priority: "low",
            summary: "Sunday lunch is on, and Dad asked whether 1pm works.",
            needsReply: true,
            reason: "Direct question about Sunday lunch",
            grounding: "direct",
            actionItems: #"["Confirm whether 1pm works"]"#,
            callbackText: nil,
            sourceMessageIds: #"["m1"]"#,
            createdAt: Date()
        )
        try repo.insertBriefCard(card)

        let cards = try repo.fetchRecentHighPriorityCards(limit: 10)

        XCTAssertEqual(cards.map(\.card.id), ["card-needs-reply"])
    }

    func testFetchRecentContextMessagesReturnsChronologicalSlice() throws {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            for i in 0..<5 {
                var msg = Message(
                    briefId: nil,
                    service: "telegram",
                    conversationId: "c1",
                    conversationName: "Joanna",
                    messageId: "m\(i)",
                    sender: "Joanna",
                    text: "msg \(i)",
                    timestamp: Date(timeIntervalSince1970: Double(100 + i)),
                    isSent: false
                )
                try msg.insert(db)
            }
        }

        let repo = BriefRepository(database: db)
        let context = try repo.fetchRecentContextMessages(
            service: "telegram",
            conversationID: "c1",
            before: Date(timeIntervalSince1970: 104),
            since: nil,
            limit: 2
        )

        XCTAssertEqual(context.map(\.messageId), ["m2", "m3"])
    }

    func testFetchLatestBriefCardReturnsNewestForConversation() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let briefID = try repo.insertBrief(makeBrief(status: "ready"))
        try repo.insertBriefCard(
            BriefCardRecord(
                id: "card-1",
                briefId: briefID,
                service: "telegram",
                conversationId: "c1",
                conversationTitle: "Joanna",
                headline: "Old headline",
                priority: "low",
                summary: "Old summary",
                actionItems: "[]",
                callbackText: nil,
                sourceMessageIds: #"["m1"]"#,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
        try repo.insertBriefCard(
            BriefCardRecord(
                id: "card-2",
                briefId: briefID,
                service: "telegram",
                conversationId: "c1",
                conversationTitle: "Joanna",
                headline: "New headline",
                priority: "high",
                summary: "New summary",
                actionItems: "[]",
                callbackText: nil,
                sourceMessageIds: #"["m2"]"#,
                createdAt: Date(timeIntervalSince1970: 200)
            )
        )

        let card = try repo.fetchLatestBriefCard(service: "telegram", conversationID: "c1")
        XCTAssertEqual(card?.id, "card-2")
    }

    func testInsertLLMRunRecordStoresMetadataOnly() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        let run = LLMRunRecord(
            briefId: nil,
            service: "telegram",
            conversationId: "c1",
            backend: "ollama",
            model: "llama3.1",
            startedAt: Date(),
            completedAt: nil,
            status: "started",
            errorCategory: nil,
            promptHash: "prompt-hash",
            responseHash: nil,
            inputTokenEstimate: nil,
            outputTokenEstimate: nil
        )

        let id = try repo.insertLLMRunRecord(run)

        XCTAssertGreaterThan(id, 0)
    }
}
