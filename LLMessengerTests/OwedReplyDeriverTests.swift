// LLMessengerTests/OwedReplyDeriverTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class OwedReplyDeriverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.dismissedKey)
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.snoozedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.dismissedKey)
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.snoozedKey)
        super.tearDown()
    }

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func insertMessage(_ db: AppDatabase,
                               service: String = "imessage",
                               conversationId: String = "conv1",
                               conversationName: String? = "Alice",
                               messageId: String,
                               text: String,
                               offset: TimeInterval,
                               isSent: Bool) throws {
        try db.dbQueue.write { grdb in
            var m = Message(
                id: nil, briefId: nil, service: service,
                conversationId: conversationId, conversationName: conversationName,
                messageId: messageId, sender: isSent ? "me" : "Alice",
                text: text, timestamp: self.now.addingTimeInterval(offset), isSent: isSent
            )
            try m.insert(grdb)
        }
    }

    private func insertTriage(_ db: AppDatabase,
                              service: String = "imessage",
                              conversationId: String = "conv1",
                              offset: TimeInterval) throws {
        try db.dbQueue.write { grdb in
            let e = TriageEvent(
                id: nil, service: service, conversationId: conversationId,
                priority: "high", needsReply: true, reason: "flagged",
                triggeredBy: "llm", notified: true,
                createdAt: self.now.addingTimeInterval(offset)
            )
            try e.insert(grdb)
        }
    }

    // 1: inbound with no reply, flagged by triage → owed
    func testInboundNoReplyFlaggedIsOwed() throws {
        let db = try makeDB()
        try insertMessage(db, messageId: "m1", text: "see attached deck", offset: -3600, isSent: false)
        try insertTriage(db, offset: -3500)
        let owed = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertEqual(owed.count, 1)
        XCTAssertEqual(owed.first?.reason, "needs reply")
    }

    // 2: inbound then a later sent reply → not owed
    func testInboundThenReplyNotOwed() throws {
        let db = try makeDB()
        try insertMessage(db, messageId: "m1", text: "can you call me?", offset: -3600, isSent: false)
        try insertMessage(db, messageId: "m2", text: "sure", offset: -3000, isSent: true)
        let owed = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertTrue(owed.isEmpty)
    }

    // 3: question-shaped inbound, no triage → owed
    func testQuestionShapedNoTriageIsOwed() throws {
        let db = try makeDB()
        try insertMessage(db, messageId: "m1", text: "are we still on for tomorrow?", offset: -7200, isSent: false)
        let owed = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertEqual(owed.count, 1)
        XCTAssertEqual(owed.first?.reason, "unanswered question")
    }

    // 4: non-question inbound, no triage → not owed
    func testNonQuestionNoTriageNotOwed() throws {
        let db = try makeDB()
        try insertMessage(db, messageId: "m1", text: "thanks for the help", offset: -7200, isSent: false)
        let owed = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertTrue(owed.isEmpty)
    }

    // 5: high-priority context ranks above low-priority context
    func testHighPriorityRanksAboveLow() throws {
        let db = try makeDB()
        try insertMessage(db, conversationId: "low", conversationName: "Low",
                          messageId: "lo1", text: "are you free?", offset: -7200, isSent: false)
        try insertMessage(db, conversationId: "high", conversationName: "Boss",
                          messageId: "hi1", text: "are you free?", offset: -7200, isSent: false)
        let contexts = [
            ConversationContext(service: "imessage", conversationId: "low", label: "", priorityHint: "low", updatedAt: now),
            ConversationContext(service: "imessage", conversationId: "high", label: "", priorityHint: "high", updatedAt: now)
        ]
        let owed = try OwedReplyDeriver().derive(db: db, contexts: contexts, now: now)
        XCTAssertEqual(owed.count, 2)
        XCTAssertEqual(owed.first?.conversationId, "high")
        XCTAssertGreaterThan(owed[0].priorityRank, owed[1].priorityRank)
    }

    // 6: snoozed entry is excluded while snooze is active
    func testSnoozedEntryExcluded() throws {
        let db = try makeDB()
        try insertMessage(db, messageId: "m1", text: "are you free?", offset: -7200, isSent: false)
        let unsnoozed = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertEqual(unsnoozed.count, 1)
        let id = unsnoozed[0].id

        OwedReplyStore.snooze(id, until: now.addingTimeInterval(86400))
        let after = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertTrue(after.isEmpty)

        OwedReplyStore.unsnooze(id)
        let restored = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertEqual(restored.count, 1)
    }

    // 7: dismissed entry is excluded
    func testDismissedEntryExcluded() throws {
        let db = try makeDB()
        try insertMessage(db, messageId: "m1", text: "are you free?", offset: -7200, isSent: false)
        let first = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        OwedReplyStore.dismiss(first[0].id)
        let after = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertTrue(after.isEmpty)

        OwedReplyStore.undismiss(first[0].id)
        let restored = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertEqual(restored.count, 1)
    }
}
