// LLMessengerTests/BriefRepositoryExtendedTests.swift
// Tests BriefRepository methods with 0% coverage:
//   storeSentMessage, markAsSent, latestBriefID, storeMessages(from:), fetchMessages(service:since:)
//
// These are not edge cases — they're production-critical paths:
//   storeSentMessage/markAsSent: every sent reply goes through these
//   latestBriefID: used by the UI to navigate to the most recent brief
//   storeMessages/fetchMessages: core of the summarizeLast DB path
import XCTest
import GRDB
@testable import LLMessenger

final class BriefRepositoryExtendedTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }
    private func makeRepo(_ db: AppDatabase) -> BriefRepository { BriefRepository(database: db) }

    private func insertBrief(_ db: AppDatabase, createdAt: Date = Date()) throws -> Int64 {
        try BriefRepository(database: db).insertBrief(
            Brief(id: nil, createdAt: createdAt, status: BriefStatus.ready.rawValue,
                  services: "[\"signal\"]", failedServices: nil, openingSummary: nil,
                  notificationText: "x", episodicSummary: nil)
        )
    }

    // MARK: - storeSentMessage

    func testStoreSentMessageIsStoredWithIsSentTrue() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        try repo.storeSentMessage(service: "signal", conversationID: "c1", text: "Hello!")

        let msg = try db.dbQueue.read { d in
            try Message.filter(Column("isSent") == true).fetchOne(d)
        }
        XCTAssertNotNil(msg, "storeSentMessage must insert a record into the messages table")
        XCTAssertTrue(msg?.isSent == true, "Stored sent message must have isSent = true")
    }

    func testStoreSentMessageIdHasSentPrefix() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        try repo.storeSentMessage(service: "signal", conversationID: "c1", text: "Hi")

        let msg = try db.dbQueue.read { d in
            try Message.fetchOne(d)
        }
        let msgId = try XCTUnwrap(msg?.messageId)
        XCTAssertTrue(msgId.hasPrefix("sent-"),
                      "storeSentMessage must use a 'sent-' prefixed messageId to distinguish sent messages from received ones")
    }

    func testStoreSentMessageHasCorrectServiceAndConversationId() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        try repo.storeSentMessage(service: "telegram", conversationID: "conv-42", text: "Hey")

        let msg = try db.dbQueue.read { d in try Message.fetchOne(d) }!
        XCTAssertEqual(msg.service, "telegram", "storeSentMessage must store the correct service")
        XCTAssertEqual(msg.conversationId, "conv-42", "storeSentMessage must store the correct conversationId")
    }

    func testStoreSentMessageHasCorrectText() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        try repo.storeSentMessage(service: "signal", conversationID: "c1", text: "Meeting at 3pm")

        let msg = try db.dbQueue.read { d in try Message.fetchOne(d) }!
        XCTAssertEqual(msg.text, "Meeting at 3pm",
                       "storeSentMessage must preserve the message text exactly")
    }

    func testStoreSentMessageSenderIsMe() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        try repo.storeSentMessage(service: "signal", conversationID: "c1", text: "Hey")

        let msg = try db.dbQueue.read { d in try Message.fetchOne(d) }!
        XCTAssertEqual(msg.sender, "me",
                       "storeSentMessage must set sender to 'me' to distinguish outgoing messages")
    }

    func testStoreSentMessageTwiceCreatesTwoRows() throws {
        // Each sent message is unique (UUID-based messageId) — must not deduplicate
        let db = try makeDB()
        let repo = makeRepo(db)

        try repo.storeSentMessage(service: "signal", conversationID: "c1", text: "First")
        try repo.storeSentMessage(service: "signal", conversationID: "c1", text: "Second")

        let count = try db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(count, 2,
                       "Two separate sent messages must both be stored — UUIDs ensure no deduplication conflict")
    }

    // MARK: - markAsSent

    func testMarkAsSentSetsIsSentFlagOnExistingMessage() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        // Insert a received message (isSent = false)
        try db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            conversationName: nil, messageId: "msg-123",
                            sender: "Alice", text: "Hi", timestamp: Date(), isSent: false)
            try m.insert(d)
        }

        try repo.markAsSent(messageID: "msg-123", service: "signal")

        let msg = try db.dbQueue.read { d in
            try Message.filter(Column("messageId") == "msg-123").fetchOne(d)
        }
        XCTAssertTrue(msg?.isSent == true,
                      "markAsSent must flip isSent to true on the specified message")
    }

    func testMarkAsSentDoesNotAffectOtherMessages() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        try db.dbQueue.write { d in
            var m1 = Message(briefId: nil, service: "signal", conversationId: "c1",
                             conversationName: nil, messageId: "msg-target",
                             sender: "Alice", text: "Hi", timestamp: Date(), isSent: false)
            var m2 = Message(briefId: nil, service: "signal", conversationId: "c1",
                             conversationName: nil, messageId: "msg-other",
                             sender: "Bob", text: "Hey", timestamp: Date(), isSent: false)
            try m1.insert(d)
            try m2.insert(d)
        }

        try repo.markAsSent(messageID: "msg-target", service: "signal")

        let other = try db.dbQueue.read { d in
            try Message.filter(Column("messageId") == "msg-other").fetchOne(d)
        }
        XCTAssertFalse(other?.isSent ?? true,
                       "markAsSent must only update the targeted message — other messages must remain unchanged")
    }

    func testMarkAsSentIsScopedToService() throws {
        // Same messageId on different services — only the matching service's message is updated
        let db = try makeDB()
        let repo = makeRepo(db)

        try db.dbQueue.write { d in
            var m1 = Message(briefId: nil, service: "signal", conversationId: "c1",
                             conversationName: nil, messageId: "shared-id",
                             sender: "Alice", text: "Hi", timestamp: Date(), isSent: false)
            var m2 = Message(briefId: nil, service: "telegram", conversationId: "c2",
                             conversationName: nil, messageId: "shared-id",
                             sender: "Bob", text: "Hey", timestamp: Date(), isSent: false)
            try m1.insert(d)
            try m2.insert(d)
        }

        try repo.markAsSent(messageID: "shared-id", service: "signal")

        let signalMsg = try db.dbQueue.read { d in
            try Message.filter(Column("service") == "signal")
                .filter(Column("messageId") == "shared-id")
                .fetchOne(d)
        }
        let telegramMsg = try db.dbQueue.read { d in
            try Message.filter(Column("service") == "telegram")
                .filter(Column("messageId") == "shared-id")
                .fetchOne(d)
        }
        XCTAssertTrue(signalMsg?.isSent == true, "markAsSent(service:'signal') must mark the signal message as sent")
        XCTAssertFalse(telegramMsg?.isSent ?? true, "markAsSent(service:'signal') must NOT affect the telegram message with the same ID")
    }

    // MARK: - latestBriefID

    func testLatestBriefIDReturnsNilWhenNoBriefs() throws {
        let db = try makeDB()
        let result = try makeRepo(db).latestBriefID()
        XCTAssertNil(result, "latestBriefID must return nil when the briefs table is empty")
    }

    func testLatestBriefIDReturnsSingleBrief() throws {
        let db = try makeDB()
        let id = try insertBrief(db)
        let latest = try makeRepo(db).latestBriefID()
        XCTAssertEqual(latest, id, "latestBriefID must return the ID of the only brief present")
    }

    func testLatestBriefIDReturnsMostRecentByCreatedAt() throws {
        let db = try makeDB()
        let now = Date()
        let oldId = try insertBrief(db, createdAt: now.addingTimeInterval(-3600))
        let newId = try insertBrief(db, createdAt: now)

        let latest = try makeRepo(db).latestBriefID()
        XCTAssertEqual(latest, newId,
                       "latestBriefID must return the brief with the most recent createdAt, not the first inserted")
        _ = oldId // suppress unused warning
    }

    func testLatestBriefIDUpdatesAfterNewBriefInserted() throws {
        let db = try makeDB()
        let now = Date()
        _ = try insertBrief(db, createdAt: now.addingTimeInterval(-60))
        let secondId = try insertBrief(db, createdAt: now)

        let latest = try makeRepo(db).latestBriefID()
        XCTAssertEqual(latest, secondId,
                       "latestBriefID must always reflect the most recently created brief")
    }

    // MARK: - storeMessages(from:service:)

    func testStoreMessagesFromAdapterResultStoresAllMessages() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        let msg1 = AdapterMessage(id: "m1", sender: "Alice", text: "Hi", timestamp: Date())
        let msg2 = AdapterMessage(id: "m2", sender: "Bob", text: "Hey", timestamp: Date())
        let conv = AdapterConversation(id: "c1", name: "Group", type: .dm, messages: [msg1, msg2])
        let result = AdapterFetchResult(conversations: [conv])

        let stored = try repo.storeMessages(from: result, service: "signal")

        XCTAssertEqual(stored.count, 2, "storeMessages must return all newly inserted messages")
        let dbCount = try db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(dbCount, 2, "storeMessages must persist all adapter messages to the DB")
    }

    func testStoreMessagesFromAdapterDeduplicatesByMessageId() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        let msg = AdapterMessage(id: "dup-m1", sender: "Alice", text: "Hi", timestamp: Date())
        let conv = AdapterConversation(id: "c1", name: "Alice", type: .dm, messages: [msg])
        let result = AdapterFetchResult(conversations: [conv])

        // First store
        let first = try repo.storeMessages(from: result, service: "signal")
        // Second store with the same message
        let second = try repo.storeMessages(from: result, service: "signal")

        XCTAssertEqual(first.count, 1, "First storeMessages call must return the newly inserted message")
        // Second call returns the already-stored message (by design — summarizeLast needs it for validation)
        let dbCount = try db.dbQueue.read { d in try Message.fetchCount(d) }
        XCTAssertEqual(dbCount, 1, "Duplicate messageId must not create a second row — INSERT OR IGNORE")
        _ = second // second may return the existing message or empty, both are valid
    }

    func testStoreMessagesPreservesConversationMetadata() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        let msg = AdapterMessage(id: "m1", sender: "Alice", text: "Hello there", timestamp: Date())
        let conv = AdapterConversation(id: "conv-alice", name: "Alice Johnson", type: .dm, messages: [msg])
        let result = AdapterFetchResult(conversations: [conv])

        _ = try repo.storeMessages(from: result, service: "signal")

        let stored = try db.dbQueue.read { d in try Message.fetchOne(d) }!
        XCTAssertEqual(stored.conversationId, "conv-alice")
        XCTAssertEqual(stored.conversationName, "Alice Johnson")
        XCTAssertEqual(stored.sender, "Alice")
        XCTAssertEqual(stored.text, "Hello there")
        XCTAssertEqual(stored.service, "signal")
        XCTAssertFalse(stored.isSent, "Adapter-sourced messages must be stored with isSent = false")
    }

    func testStoreMessagesAcrossMultipleConversations() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        let conv1 = AdapterConversation(id: "c1", name: "Alice", type: .dm,
                                         messages: [AdapterMessage(id: "m1", sender: "Alice", text: "Hi", timestamp: Date())])
        let conv2 = AdapterConversation(id: "c2", name: "Bob", type: .dm,
                                         messages: [AdapterMessage(id: "m2", sender: "Bob", text: "Hey", timestamp: Date()),
                                                    AdapterMessage(id: "m3", sender: "Bob", text: "Sup", timestamp: Date())])
        let result = AdapterFetchResult(conversations: [conv1, conv2])

        let stored = try repo.storeMessages(from: result, service: "signal")
        XCTAssertEqual(stored.count, 3, "storeMessages must process all conversations and all their messages")
    }

    // MARK: - fetchMessages(service:since:)

    func testFetchMessagesReturnsMessagesAfterSinceDate() throws {
        let db = try makeDB()
        let repo = makeRepo(db)
        let now = Date()

        try db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            conversationName: nil, messageId: "recent",
                            sender: "Alice", text: "Recent", timestamp: now, isSent: false)
            try m.insert(d)
        }

        let result = try repo.fetchMessages(service: "signal", since: now.addingTimeInterval(-60))
        XCTAssertEqual(result.count, 1, "fetchMessages must return messages with timestamp > since")
        XCTAssertEqual(result[0].messageId, "recent")
    }

    func testFetchMessagesExcludesMessagesBeforeSinceDate() throws {
        let db = try makeDB()
        let repo = makeRepo(db)
        let cutoff = Date()

        try db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            conversationName: nil, messageId: "old",
                            sender: "Alice", text: "Old",
                            timestamp: cutoff.addingTimeInterval(-7200), isSent: false)
            try m.insert(d)
        }

        let result = try repo.fetchMessages(service: "signal", since: cutoff.addingTimeInterval(-3600))
        XCTAssertEqual(result.count, 0,
                       "fetchMessages must exclude messages older than the 'since' date")
    }

    func testFetchMessagesIncludesSentMessagesForContext() throws {
        let db = try makeDB()
        let repo = makeRepo(db)
        let since = Date().addingTimeInterval(-60)

        try db.dbQueue.write { d in
            var received = Message(briefId: nil, service: "signal", conversationId: "c1",
                                   conversationName: nil, messageId: "received-m1",
                                   sender: "Alice", text: "Hi", timestamp: Date(), isSent: false)
            var sent = Message(briefId: nil, service: "signal", conversationId: "c1",
                               conversationName: nil, messageId: "sent-m1",
                               sender: "me", text: "Hi back", timestamp: Date(), isSent: true)
            try received.insert(d)
            try sent.insert(d)
        }

        let result = try repo.fetchMessages(service: "signal", since: since)
        XCTAssertEqual(result.count, 2, "fetchMessages must include sent messages — they provide conversation context for the LLM")
    }

    func testFetchMessagesScopedToService() throws {
        let db = try makeDB()
        let repo = makeRepo(db)
        let since = Date().addingTimeInterval(-60)

        try db.dbQueue.write { d in
            var sig = Message(briefId: nil, service: "signal", conversationId: "c1",
                              conversationName: nil, messageId: "sig-m1",
                              sender: "Alice", text: "Hi", timestamp: Date(), isSent: false)
            var tg = Message(briefId: nil, service: "telegram", conversationId: "c2",
                             conversationName: nil, messageId: "tg-m1",
                             sender: "Bob", text: "Hey", timestamp: Date(), isSent: false)
            try sig.insert(d)
            try tg.insert(d)
        }

        let signalMessages = try repo.fetchMessages(service: "signal", since: since)
        XCTAssertEqual(signalMessages.count, 1, "fetchMessages must only return messages for the requested service")
        XCTAssertEqual(signalMessages[0].service, "signal")

        let telegramMessages = try repo.fetchMessages(service: "telegram", since: since)
        XCTAssertEqual(telegramMessages.count, 1, "fetchMessages for telegram must only return telegram messages")
    }

    func testFetchMessagesReturnsSortedByTimestampAscending() throws {
        let db = try makeDB()
        let repo = makeRepo(db)
        let base = Date().addingTimeInterval(-300)

        try db.dbQueue.write { d in
            // Insert out of order
            var m3 = Message(briefId: nil, service: "signal", conversationId: "c1",
                             conversationName: nil, messageId: "m3",
                             sender: "Alice", text: "Third", timestamp: base.addingTimeInterval(20), isSent: false)
            var m1 = Message(briefId: nil, service: "signal", conversationId: "c1",
                             conversationName: nil, messageId: "m1",
                             sender: "Alice", text: "First", timestamp: base, isSent: false)
            var m2 = Message(briefId: nil, service: "signal", conversationId: "c1",
                             conversationName: nil, messageId: "m2",
                             sender: "Alice", text: "Second", timestamp: base.addingTimeInterval(10), isSent: false)
            try m3.insert(d)
            try m1.insert(d)
            try m2.insert(d)
        }

        let results = try repo.fetchMessages(service: "signal", since: base.addingTimeInterval(-1))
        XCTAssertEqual(results.map(\.messageId), ["m1", "m2", "m3"],
                       "fetchMessages must return messages sorted by timestamp ascending")
    }

    func testFetchMessagesReturnsEmptyWhenNoneMatch() throws {
        let db = try makeDB()
        let repo = makeRepo(db)

        let result = try repo.fetchMessages(service: "signal", since: Date().addingTimeInterval(-60))
        XCTAssertTrue(result.isEmpty, "fetchMessages must return an empty array when no messages match")
    }
}
