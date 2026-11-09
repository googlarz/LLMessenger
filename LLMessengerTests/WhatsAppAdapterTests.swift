// LLMessengerTests/WhatsAppAdapterTests.swift
//
// Every test builds a synthetic ChatStorage.sqlite in a temp directory with invented
// data. Nothing here touches a real WhatsApp store.

import XCTest
import GRDB
@testable import LLMessenger

final class WhatsAppAdapterTests: XCTestCase {

    // MARK: - Fixture

    private var dir: URL!
    private var storeURL: URL { dir.appendingPathComponent("ChatStorage.sqlite") }
    private var store: DatabaseQueue!

    /// 2023-11-14 22:13:20 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wa-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try DatabaseQueue(path: storeURL.path)
        try store.write { db in
            try db.execute(sql: """
                CREATE TABLE ZWACHATSESSION (
                    Z_PK INTEGER PRIMARY KEY, ZARCHIVED INTEGER, ZHIDDEN INTEGER, ZREMOVED INTEGER,
                    ZSESSIONTYPE INTEGER, ZLASTMESSAGEDATE TIMESTAMP,
                    ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR);
                CREATE TABLE ZWAGROUPMEMBER (
                    Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER,
                    ZCONTACTNAME VARCHAR, ZFIRSTNAME VARCHAR, ZMEMBERJID VARCHAR);
                CREATE TABLE ZWAMESSAGE (
                    Z_PK INTEGER PRIMARY KEY, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER,
                    ZCHATSESSION INTEGER, ZGROUPMEMBER INTEGER, ZMESSAGEDATE TIMESTAMP,
                    ZFROMJID VARCHAR, ZPUSHNAME VARCHAR, ZSTANZAID VARCHAR, ZTEXT VARCHAR, ZTOJID VARCHAR);
                """)
        }
    }

    override func tearDownWithError() throws {
        store = nil
        // Restore permissions a test may have removed so the directory can be deleted.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeURL.path)
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func ref(_ date: Date) -> Double { date.timeIntervalSince1970 - 978_307_200 }

    private func addChat(_ pk: Int, jid: String, name: String?, hidden: Int = 0, removed: Int = 0) throws {
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO ZWACHATSESSION (Z_PK, ZARCHIVED, ZHIDDEN, ZREMOVED, ZSESSIONTYPE, ZCONTACTJID, ZPARTNERNAME)
                VALUES (?, 0, ?, ?, 0, ?, ?)
                """, arguments: [pk, hidden, removed, jid, name])
        }
    }

    private func addMember(_ pk: Int, chat: Int, name: String?, first: String?, jid: String) throws {
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO ZWAGROUPMEMBER (Z_PK, ZCHATSESSION, ZCONTACTNAME, ZFIRSTNAME, ZMEMBERJID)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [pk, chat, name, first, jid])
        }
    }

    private func addMessage(_ pk: Int, chat: Int, stanza: String?, text: String?, at date: Date,
                            fromMe: Bool = false, type: Int? = 0, member: Int? = nil,
                            push: String? = nil, fromJID: String? = nil, integerDate: Bool = false) throws {
        // Real stores hold ZMESSAGEDATE as INTEGER or REAL; cover both.
        let stored: DatabaseValueConvertible = integerDate ? Int64(ref(date)) : ref(date)
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO ZWAMESSAGE (Z_PK, ZISFROMME, ZMESSAGETYPE, ZCHATSESSION, ZGROUPMEMBER,
                                        ZMESSAGEDATE, ZFROMJID, ZPUSHNAME, ZSTANZAID, ZTEXT)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [pk, fromMe ? 1 : 0, type, chat, member, stored, fromJID, push, stanza, text])
        }
    }

    /// The adapter's clock is pinned just after `t0` so fixtures dated at `t0` fall
    /// inside its 7-day history cap.
    private func makeAdapter(now: Date? = nil, busyTimeout: TimeInterval = 2) -> WhatsAppAdapter {
        let clock = now ?? t0.addingTimeInterval(3600)
        return WhatsAppAdapter(storePath: storeURL.path, busyTimeout: busyTimeout, now: { clock })
    }

    private func directoryListing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func fetchAll(_ adapter: WhatsAppAdapter, since: Date? = nil) async throws -> [AdapterConversation] {
        try await adapter.fetch(config: FetchConfig(mode: .byTime(since: since ?? t0.addingTimeInterval(-86_400)))).conversations
    }

    private func messages(_ conversations: [AdapterConversation]) -> [AdapterMessage] {
        conversations.flatMap(\.messages)
    }

    private let aliceJID = "15550100@s.whatsapp.net"
    private let groupJID = "120363000000000001@g.us"

    // MARK: - Ingest

    func testTextMessagesIngestedAndMediaSystemEmptySkipped() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "A1", text: "Lunch tomorrow?", at: t0)
        try addMessage(2, chat: 1, stanza: "A2", text: "photo caption", at: t0, type: 1)      // media
        try addMessage(3, chat: 1, stanza: "A3", text: "group renamed", at: t0, type: 10)    // system
        try addMessage(4, chat: 1, stanza: "A4", text: "", at: t0)                           // empty
        try addMessage(5, chat: 1, stanza: "A5", text: nil, at: t0)                          // NULL
        try addMessage(6, chat: 1, stanza: "A6", text: "   ", at: t0)                        // blank
        try addMessage(7, chat: 1, stanza: nil, text: "no stanza id", at: t0)                // unidentifiable
        let adapter = makeAdapter()
        try await adapter.start()

        let conversations = try await fetchAll(adapter)
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].id, aliceJID)
        XCTAssertEqual(conversations[0].name, "Alice")
        XCTAssertEqual(conversations[0].type, .dm)
        XCTAssertEqual(messages(conversations).map(\.text), ["Lunch tomorrow?"])
    }

    func testLinkMessagesAreIngested() async throws {
        // WhatsApp stores a text message that contains a URL as type 7, not 0.
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "L1", text: "Can you sign this? https://example.com/doc", at: t0, type: 7)
        let adapter = makeAdapter()
        try await adapter.start()

        let conversations = try await fetchAll(adapter)
        XCTAssertEqual(messages(conversations).map(\.text), ["Can you sign this? https://example.com/doc"])
    }

    func testCoreDataDateConvertedToUnixTime() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "A1", text: "hi", at: t0)
        let adapter = makeAdapter()
        try await adapter.start()
        let fetched = try await fetchAll(adapter)
        let msg = try XCTUnwrap(messages(fetched).first)
        XCTAssertEqual(msg.timestamp.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testOwnVersusIncomingMessages() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "A1", text: "incoming", at: t0)
        try addMessage(2, chat: 1, stanza: "A2", text: "outgoing", at: t0.addingTimeInterval(1), fromMe: true)
        let adapter = makeAdapter()
        try await adapter.start()
        let msgs = messages(try await fetchAll(adapter))
        XCTAssertEqual(msgs.map(\.isFromMe), [false, true])
        XCTAssertEqual(msgs[0].sender, "Alice")
        XCTAssertEqual(msgs[1].sender, "Me")
    }

    func testDirectChatFallsBackToPushNameThenNumber() async throws {
        try addChat(1, jid: aliceJID, name: nil)
        try addMessage(1, chat: 1, stanza: "A1", text: "from push name", at: t0, push: "Ali P")
        try addChat(2, jid: "15550199@s.whatsapp.net", name: "")
        try addMessage(2, chat: 2, stanza: "B1", text: "no names at all", at: t0.addingTimeInterval(1))
        let adapter = makeAdapter()
        try await adapter.start()
        let byConv = Dictionary(uniqueKeysWithValues: try await fetchAll(adapter).map { ($0.id, $0) })
        XCTAssertEqual(byConv[aliceJID]?.messages.first?.sender, "Ali P")
        XCTAssertEqual(byConv[aliceJID]?.name, "+15550100")
        XCTAssertEqual(byConv["15550199@s.whatsapp.net"]?.messages.first?.sender, "+15550199")
    }

    func testGroupSenderNameResolved() async throws {
        try addChat(1, jid: groupJID, name: "Book club")
        try addMember(10, chat: 1, name: "Bea Example", first: "Bea", jid: "15550111@s.whatsapp.net")
        try addMember(11, chat: 1, name: nil, first: "Carl", jid: "15550112@s.whatsapp.net")
        try addMember(12, chat: 1, name: nil, first: nil, jid: "15550113@s.whatsapp.net")
        try addMessage(1, chat: 1, stanza: "G1", text: "full name", at: t0, member: 10)
        try addMessage(2, chat: 1, stanza: "G2", text: "first name", at: t0.addingTimeInterval(1), member: 11)
        try addMessage(3, chat: 1, stanza: "G3", text: "push name", at: t0.addingTimeInterval(2), member: 12, push: "Dee")
        try addMessage(4, chat: 1, stanza: "G4", text: "number only", at: t0.addingTimeInterval(3), member: 12)
        try addMessage(5, chat: 1, stanza: "G5", text: "mine", at: t0.addingTimeInterval(4), fromMe: true)
        let adapter = makeAdapter()
        try await adapter.start()
        let conversations = try await fetchAll(adapter)
        XCTAssertEqual(conversations.first?.type, .group)
        XCTAssertEqual(conversations.first?.name, "Book club")
        XCTAssertEqual(messages(conversations).map(\.sender),
                       ["Bea Example", "Carl", "Dee", "+15550113", "Me"])
    }

    func testStatusBroadcastHiddenRemovedAndUnknownChatsSkipped() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addChat(2, jid: "status@broadcast", name: "Status")
        try addChat(3, jid: "1555@broadcast", name: "List")
        try addChat(4, jid: "15550120@s.whatsapp.net", name: "Hidden", hidden: 1)
        try addChat(5, jid: "15550121@s.whatsapp.net", name: "Removed", removed: 1)
        try addChat(6, jid: "123@newsletter", name: "Channel")
        for chat in 1...6 {
            try addMessage(chat, chat: chat, stanza: "S\(chat)", text: "text \(chat)", at: t0)
        }
        let adapter = makeAdapter()
        try await adapter.start()
        let fetched = try await fetchAll(adapter)
        XCTAssertEqual(fetched.map(\.id), [aliceJID])
    }

    func testLidChatIsIngestedAsDirectChat() async throws {
        try addChat(1, jid: "98765432101234@lid", name: "Lid Person")
        try addMessage(1, chat: 1, stanza: "L1", text: "hello", at: t0)
        let adapter = makeAdapter()
        try await adapter.start()
        let fetched = try await fetchAll(adapter)
        let conv = try XCTUnwrap(fetched.first)
        XCTAssertEqual(conv.type, .dm)
        XCTAssertEqual(conv.messages.first?.sender, "Lid Person")
    }

    // MARK: - Identity and incremental polling

    func testSameStanzaInTwoChatsGivesDistinctMessageIDs() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addChat(2, jid: groupJID, name: "Group")
        try addMessage(1, chat: 1, stanza: "SAME", text: "one", at: t0)
        try addMessage(2, chat: 2, stanza: "SAME", text: "two", at: t0)
        let adapter = makeAdapter()
        try await adapter.start()
        let ids = messages(try await fetchAll(adapter)).map(\.id)
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertTrue(ids.contains(WhatsAppAdapter.messageID(chatJID: aliceJID, stanzaID: "SAME")))
        XCTAssertTrue(ids.contains(WhatsAppAdapter.messageID(chatJID: groupJID, stanzaID: "SAME")))
    }

    func testSecondPollStoresOnlyNewMessages() async throws {
        // The adapter re-reads a 24 h overlap on every poll; the ingestion layer's
        // insert-ignore is what keeps repeats from becoming "new" messages.
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "A1", text: "old", at: t0)
        let db = try AppDatabase(inMemory: true)
        let coordinator = MessageIngestionCoordinator(database: db)
        let adapter = makeAdapter()
        try await adapter.start()
        let first = try await coordinator.ingest(
            service: "whatsapp", adapter: adapter, config: FetchConfig(mode: .byTime(since: t0.addingTimeInterval(-86_400))))
        XCTAssertEqual(first.newMessages.map(\.text), ["old"])

        let cursor = t0.addingTimeInterval(10)
        try addMessage(2, chat: 1, stanza: "A2", text: "new", at: t0.addingTimeInterval(20))
        let reread = messages(try await fetchAll(adapter, since: cursor))
        XCTAssertEqual(reread.map(\.text), ["old", "new"], "overlap re-reads the earlier message")
        let second = try await coordinator.ingest(
            service: "whatsapp", adapter: adapter, config: FetchConfig(mode: .byTime(since: cursor)))
        XCTAssertEqual(second.newMessages.map(\.text), ["new"])
    }

    func testByCountKeepsOnlyTheMostRecentMessages() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        let now = Date()
        for i in 0..<5 {
            try addMessage(i + 1, chat: 1, stanza: "A\(i)", text: "m\(i)", at: now.addingTimeInterval(Double(i) - 100))
        }
        let adapter = WhatsAppAdapter(storePath: storeURL.path) // real clock: messages are dated "now"
        try await adapter.start()
        let result = try await adapter.fetch(config: FetchConfig(mode: .byCount(last: 2)))
        XCTAssertEqual(messages(result.conversations).map(\.text), ["m3", "m4"])
    }

    func testResyncWithNewPrimaryKeysDoesNotDuplicate() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "A1", text: "hello", at: t0)
        try addMessage(2, chat: 1, stanza: "A2", text: "again", at: t0.addingTimeInterval(1))

        let db = try AppDatabase(inMemory: true)
        let coordinator = MessageIngestionCoordinator(database: db)
        let adapter = makeAdapter()
        try await adapter.start()
        let config = FetchConfig(mode: .byTime(since: t0.addingTimeInterval(-86_400)))

        let first = try await coordinator.ingest(service: "whatsapp", adapter: adapter, config: config)
        XCTAssertEqual(first.newMessages.count, 2)

        // Re-sync: WhatsApp rewrites the rows under different Z_PKs (and leaves the old
        // copies in place too), with the same chat JID and stanza ids.
        try await store.write { db in
            try db.execute(sql: "UPDATE ZWAMESSAGE SET Z_PK = Z_PK + 100")
        }
        try addMessage(1, chat: 1, stanza: "A1", text: "hello", at: t0)
        try addMessage(2, chat: 1, stanza: "A2", text: "again", at: t0.addingTimeInterval(1))

        let oneShot = messages(try await fetchAll(adapter))
        XCTAssertEqual(oneShot.count, 2, "adapter must collapse duplicate chat+stanza rows")

        let second = try await coordinator.ingest(service: "whatsapp", adapter: adapter, config: config)
        XCTAssertTrue(second.newMessages.isEmpty)
        let stored = try await db.dbQueue.read { try Message.fetchCount($0) }
        XCTAssertEqual(stored, 2)
    }

    func testIngestedMessagesCarrySentFlagForOwedReplies() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "A1", text: "question?", at: t0)
        try addMessage(2, chat: 1, stanza: "A2", text: "answer", at: t0.addingTimeInterval(1), fromMe: true)
        let db = try AppDatabase(inMemory: true)
        let adapter = makeAdapter()
        try await adapter.start()
        _ = try await MessageIngestionCoordinator(database: db).ingest(
            service: "whatsapp", adapter: adapter,
            config: FetchConfig(mode: .byTime(since: t0.addingTimeInterval(-86_400))))
        let rows = try await db.dbQueue.read { try Message.order(Column("timestamp")).fetchAll($0) }
        XCTAssertEqual(rows.map(\.isSent), [false, true])
        XCTAssertEqual(rows.first?.service, "whatsapp")
    }

    // MARK: - Missing / unreadable store

    func testMissingStoreReportsNotFoundWithoutCrashing() async throws {
        let adapter = WhatsAppAdapter(storePath: dir.appendingPathComponent("nope.sqlite").path)
        let health = await adapter.healthCheck()
        XCTAssertEqual(health.status, .warning)
        XCTAssertTrue(health.reason?.contains("WhatsApp Desktop not found") == true)

        do {
            try await adapter.start()
            XCTFail("start must throw when the store is missing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("WhatsApp Desktop not found"))
        }
        do {
            _ = try await adapter.fetch(config: FetchConfig(mode: .byTime(since: t0)))
            XCTFail("fetch must throw before a successful start")
        } catch {
            // expected: a disabled or unstarted adapter never reads anything
        }
    }

    func testPermissionDeniedReportsFullDiskAccessHint() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try store.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storeURL.path)
        let adapter = makeAdapter()
        let health = await adapter.healthCheck()
        XCTAssertEqual(health.status, .error)
        XCTAssertTrue(health.reason?.contains("Full Disk Access") == true)
        do {
            try await adapter.start()
            XCTFail("start must throw for an unreadable store")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Full Disk Access"))
        }
    }

    func testNotADatabaseIsAFormatProblemNotAPermissionProblem() async throws {
        try Data("not a sqlite file, just padding to look like one".utf8).write(to: dir.appendingPathComponent("junk.sqlite"))
        let adapter = WhatsAppAdapter(storePath: dir.appendingPathComponent("junk.sqlite").path)
        let health = await adapter.healthCheck()
        XCTAssertEqual(health.status, .error)
        XCTAssertEqual(health.reason, WhatsAppAdapter.formatChangedReason)
        XCTAssertFalse(health.reason?.contains("Full Disk Access") == true)
    }

    func testMissingMessageTableReportsFormatChange() async throws {
        let other = dir.appendingPathComponent("other.sqlite")
        let q = try DatabaseQueue(path: other.path)
        try await q.write { try $0.execute(sql: "CREATE TABLE ZSOMETHING (Z_PK INTEGER PRIMARY KEY)") }
        let adapter = WhatsAppAdapter(storePath: other.path)
        do {
            try await adapter.start()
            XCTFail("start must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("format may have changed"))
            XCTAssertFalse(error.localizedDescription.contains("Full Disk Access"))
        }
    }

    func testSchemaMismatchOnFetchReportsFormatChangeNotFullDiskAccess() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "A1", text: "hi", at: t0)
        let adapter = makeAdapter()
        try await adapter.start()
        try await store.write { try $0.execute(sql: "ALTER TABLE ZWAMESSAGE RENAME COLUMN ZTEXT TO ZBODY") }
        do {
            _ = try await fetchAll(adapter)
            XCTFail("fetch must throw when a column is gone")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("format may have changed"))
            XCTAssertFalse(error.localizedDescription.contains("Full Disk Access"))
        }
    }

    func testBusyStoreIsATemporaryWarningNotFullDiskAccess() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "A1", text: "hi", at: t0)
        let adapter = makeAdapter(busyTimeout: 0.05)
        try await adapter.start()

        var cfg = Configuration()
        cfg.allowsUnsafeTransactions = true
        let locker = try DatabaseQueue(path: storeURL.path, configuration: cfg)
        try await locker.writeWithoutTransaction { try $0.execute(sql: "BEGIN EXCLUSIVE") }
        defer { try? locker.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") } }

        let health = await adapter.healthCheck()
        XCTAssertEqual(health.status, .warning)
        XCTAssertEqual(health.reason, WhatsAppAdapter.busyReason)
        XCTAssertFalse(health.reason?.contains("Full Disk Access") == true)

        let result = try await adapter.fetch(config: FetchConfig(mode: .byTime(since: t0.addingTimeInterval(-60))))
        XCTAssertTrue(result.conversations.isEmpty, "a busy read yields nothing and is retried, it does not throw")
        XCTAssertEqual(adapter.healthStatus, .warning)

        // A fresh adapter started while the store is locked is startable, with a warning.
        let late = makeAdapter(busyTimeout: 0.05)
        try await late.start()
        XCTAssertEqual(late.healthStatus, .warning)
    }

    func testHealthIsOkAfterStart() async throws {
        let adapter = makeAdapter()
        try await adapter.start()
        let health = await adapter.healthCheck()
        XCTAssertEqual(health.status, .ok)
        XCTAssertEqual(adapter.healthStatus, .ok)
    }

    func testReadOnlyConnectionNeverModifiesStore() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "A1", text: "hello", at: t0)
        try store.close()
        let before = try Data(contentsOf: storeURL)
        let adapter = makeAdapter()
        try await adapter.start()
        _ = try await fetchAll(adapter)
        _ = await adapter.healthCheck()
        XCTAssertEqual(try Data(contentsOf: storeURL), before)
    }

    // MARK: - Late sync, history cap, own media

    func testLateSyncedMessageOlderThanCursorIsReturned() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        let cursor = t0
        try addMessage(1, chat: 1, stanza: "LATE", text: "synced late", at: cursor.addingTimeInterval(-3 * 3600))
        try addMessage(2, chat: 1, stanza: "OLD", text: "too old", at: cursor.addingTimeInterval(-25 * 3600))
        let adapter = makeAdapter(now: cursor.addingTimeInterval(60))
        try await adapter.start()
        let msgs = messages(try await fetchAll(adapter, since: cursor))
        XCTAssertEqual(msgs.map(\.text), ["synced late"])
    }

    func testReadNeverGoesBeyondSevenDays() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        let now = t0
        try addMessage(1, chat: 1, stanza: "OLD", text: "eight days", at: now.addingTimeInterval(-8 * 86_400))
        try addMessage(2, chat: 1, stanza: "NEW", text: "six days", at: now.addingTimeInterval(-6 * 86_400))
        let adapter = makeAdapter(now: now)
        try await adapter.start()
        // The cursor is a month stale (service was disabled for weeks).
        let msgs = messages(try await fetchAll(adapter, since: now.addingTimeInterval(-30 * 86_400)))
        XCTAssertEqual(msgs.map(\.text), ["six days"])
    }

    func testOwnMediaRepliesIngestedAsPlaceholderAndInboundMediaSkipped() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        var pk = 0
        func add(_ stanza: String, type: Int?, fromMe: Bool, text: String? = nil) throws {
            pk += 1
            try addMessage(pk, chat: 1, stanza: stanza, text: text, at: t0.addingTimeInterval(Double(pk)),
                           fromMe: fromMe, type: type)
        }
        try add("MY-IMG", type: 1, fromMe: true)
        try add("MY-VOICE", type: 3, fromMe: true, text: "")
        try add("MY-STICKER", type: 15, fromMe: true)
        try add("MY-DOC", type: 8, fromMe: true, text: "a caption")
        try add("IN-IMG", type: 1, fromMe: false, text: "their caption")
        try add("IN-VOICE", type: 3, fromMe: false)
        try add("MY-SYS6", type: 6, fromMe: true, text: "15550100@s.whatsapp.net")
        try add("MY-SYS10", type: 10, fromMe: true, text: "15550100@s.whatsapp.net")
        try add("MY-DELETED", type: 14, fromMe: true)
        try add("MY-UNKNOWN", type: 99, fromMe: true)
        try add("MY-NOTYPE", type: nil, fromMe: true)
        let adapter = makeAdapter(now: t0.addingTimeInterval(100))
        try await adapter.start()
        let msgs = messages(try await fetchAll(adapter))
        XCTAssertEqual(msgs.map(\.id), ["MY-IMG", "MY-VOICE", "MY-STICKER", "MY-DOC"].map {
            WhatsAppAdapter.messageID(chatJID: aliceJID, stanzaID: $0)
        })
        XCTAssertEqual(Set(msgs.map(\.text)), ["[media]"])
        XCTAssertTrue(msgs.allSatisfy(\.isFromMe))
    }

    func testOwnMediaReplyClearsOwedReply() async throws {
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "Q", text: "Can you call me tomorrow?", at: t0)
        let now = t0.addingTimeInterval(3600)
        let db = try AppDatabase(inMemory: true)
        let adapter = makeAdapter(now: now)
        try await adapter.start()
        let coordinator = MessageIngestionCoordinator(database: db)
        let config = FetchConfig(mode: .byTime(since: t0.addingTimeInterval(-60)))
        _ = try await coordinator.ingest(service: "whatsapp", adapter: adapter, config: config)
        let before = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertEqual(before.filter { $0.service == "whatsapp" }.count, 1)

        try addMessage(2, chat: 1, stanza: "VOICE", text: nil, at: t0.addingTimeInterval(600), fromMe: true, type: 3)
        _ = try await coordinator.ingest(service: "whatsapp", adapter: adapter, config: config)
        let after = try OwedReplyDeriver().derive(db: db, contexts: [], now: now)
        XCTAssertTrue(after.filter { $0.service == "whatsapp" }.isEmpty)
    }

    // MARK: - Realistic store: WAL mode, INTEGER dates, no side effects

    func testWALStoreWithIntegerDatesIsReadWhileWriterIsOpen() async throws {
        try await store.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=WAL") }
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "I1", text: "integer date", at: t0, integerDate: true)
        try addMessage(2, chat: 1, stanza: "I2", text: "real date", at: t0.addingTimeInterval(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path + "-wal"), "fixture must really be in WAL mode")
        let adapter = makeAdapter()
        try await adapter.start()
        let msgs = messages(try await fetchAll(adapter))
        XCTAssertEqual(msgs.map(\.text), ["integer date", "real date"])
        XCTAssertEqual(msgs[0].timestamp.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testReadingClosedWALStoreCreatesNoFiles() async throws {
        try await store.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=WAL") }
        try addChat(1, jid: aliceJID, name: "Alice")
        try addMessage(1, chat: 1, stanza: "I1", text: "integer date", at: t0, integerDate: true)
        // WhatsApp not running: everything checkpointed, no -wal/-shm left, file still in WAL mode.
        try await store.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try store.close()
        store = nil
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
        }
        XCTAssertEqual(try directoryListing(), ["ChatStorage.sqlite"])

        let adapter = makeAdapter()
        try await adapter.start()
        let msgs = messages(try await fetchAll(adapter))
        _ = await adapter.healthCheck()
        XCTAssertEqual(msgs.map(\.text), ["integer date"])
        XCTAssertEqual(try directoryListing(), ["ChatStorage.sqlite"], "a read-only open must not create -wal/-shm")
    }

    // MARK: - Read-only / cannot send

    func testSendFailsWithReadOnlyError() async throws {
        let adapter = makeAdapter()
        do {
            try await adapter.send(conversationID: aliceJID, text: "hi")
            XCTFail("send must fail")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "WhatsApp is read-only in LLMessenger — reply in WhatsApp")
        }
    }

    func testListContactsIsEmpty() async {
        let contacts = await makeAdapter().listContacts()
        XCTAssertTrue(contacts.isEmpty)
    }

    func testCapabilityFlagOnlyBlocksWhatsApp() {
        XCTAssertFalse(ServiceCapabilities.canSend(service: "whatsapp"))
        for service in ["imessage", "signal", "telegram", "slack"] {
            XCTAssertTrue(ServiceCapabilities.canSend(service: service), service)
        }
    }

    func testPhoneDigitsOnlyForDialableDirectJIDs() {
        XCTAssertEqual(WhatsAppAdapter.phoneDigits(fromJID: "15550100@s.whatsapp.net"), "15550100")
        XCTAssertEqual(WhatsAppAdapter.phoneDigits(fromJID: "15550100:12@s.whatsapp.net"), "15550100")
        XCTAssertNil(WhatsAppAdapter.phoneDigits(fromJID: "120363000000000001@g.us"))
        XCTAssertNil(WhatsAppAdapter.phoneDigits(fromJID: "98765@lid"))
    }

    func testDefaultConfigIsDisabledOnlyForWhatsApp() {
        XCTAssertFalse(ServiceConfig.default(for: "whatsapp").enabled)
        XCTAssertTrue(ServiceConfig.default(for: "imessage").enabled)
    }

    // MARK: - Agent never queues a send for WhatsApp

    private actor RoutingLLM: LLMClient {
        private(set) var replyDraftCalls = 0
        nonisolated var isLocal: Bool { false }

        func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
            let prompt = messages.map(\.content).joined(separator: "\n")
            if prompt.contains("You are drafting a reply") {
                replyDraftCalls += 1
                return LLMResponse(
                    text: #"{"title":"Reply","draftText":"Sure","reasoning":"r","confidence":0.8}"#,
                    inputTokens: 0, outputTokens: 0)
            }
            if prompt.contains("scheduling proposals") {
                let start = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
                let end = ISO8601DateFormatter().string(from: Date().addingTimeInterval(90_000))
                return LLMResponse(
                    text: #"{"schedule":[{"title":"Dinner","startISO":"\#(start)","endISO":"\#(end)","isInvite":true}]}"#,
                    inputTokens: 0, outputTokens: 0)
            }
            return LLMResponse(text: "{}", inputTokens: 0, outputTokens: 0)
        }
    }

    private func seedInbound(_ db: AppDatabase, service: String) async throws {
        try await db.dbQueue.write { d in
            var m = Message(id: nil, briefId: nil, service: service, conversationId: "c1",
                            conversationName: "Alice", messageId: "in-\(service)", sender: "Alice",
                            text: "Dinner on Friday at 7, can you make it?",
                            timestamp: Date().addingTimeInterval(-3600), isSent: false)
            try m.insert(d)
        }
    }

    func testAgentQueuesNoSendActionForWhatsAppButDoesForIMessage() async throws {
        UserDefaults.standard.removeObject(forKey: "agentDisabled")
        UserDefaults.standard.removeObject(forKey: "calendarProposalWatermarks")
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.dismissedKey)
        UserDefaults.standard.removeObject(forKey: OwedReplyStore.snoozedKey)
        defer { UserDefaults.standard.removeObject(forKey: "calendarProposalWatermarks") }

        let db = try AppDatabase(inMemory: true)
        try await seedInbound(db, service: "whatsapp")
        try await seedInbound(db, service: "imessage")
        let llm = RoutingLLM()
        let engine = AgentEngine(db: db, llmClient: llm, llmModel: "test",
                                 repository: BriefRepository(database: db), rulesProvider: { [] })
        await engine.trigger()

        let actions = try await db.dbQueue.read { try AgentAction.fetchAll($0) }
        let whatsApp = actions.filter { $0.service == "whatsapp" }
        let iMessage = actions.filter { $0.service == "imessage" }

        XCTAssertFalse(whatsApp.contains { $0.kindEnum == .reply || $0.kindEnum == .rsvp || $0.kindEnum == .followUp || $0.kindEnum == .ack },
                       "no approvable send action may exist for a read-only service")
        XCTAssertEqual(whatsApp.map(\.kindEnum), [.calendarHold], "an invite degrades to a local calendar hold")
        XCTAssertTrue(iMessage.contains { $0.kindEnum == .reply })
        XCTAssertTrue(iMessage.contains { $0.kindEnum == .rsvp })
        let draftCalls = await llm.replyDraftCalls
        XCTAssertEqual(draftCalls, 1, "no reply is even drafted for WhatsApp")
    }

    func testNoFollowUpIsGeneratedForCantSendServiceButIsForSignal() async throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        for service in ["whatsapp", "signal"] {
            try repo.insertCommitment(Commitment(
                id: nil, direction: CommitmentDirection.theyOwe.rawValue, service: service,
                conversationId: "c-\(service)", conversationName: "Bob", what: "the cap table",
                dueAt: Date().addingTimeInterval(-3600), evidenceMessageId: nil,
                status: CommitmentStatus.open.rawValue, createdAt: Date().addingTimeInterval(-7200)))
        }
        let engine = AgentEngine(db: db, llmClient: ScriptedLLMClient(response: #"{"commitments": []}"#),
                                 llmModel: "test", repository: repo, rulesProvider: { [] })

        let produced = await engine.deriveCommitmentsAndProposeFollowUps()
        XCTAssertTrue(produced)
        let actions = try await db.dbQueue.read { try AgentAction.fetchAll($0) }
        XCTAssertEqual(actions.map(\.service), ["signal"], "no follow-up may be built for a service that cannot send")
    }

    func testMCPProposalRefusesWhatsApp() async throws {
        let db = try AppDatabase(inMemory: true)
        try await seedInbound(db, service: "whatsapp")
        let toolbox = MCPToolbox(
            settings: MCPSettingsReader(isEnabled: { true }, isGlobalLocalOnly: { false }),
            openReader: { db }, openWriter: { db })
        let out = toolbox.call(tool: "propose_reply",
                               arguments: ["service": "whatsapp", "conversation_id": "c1", "text": "ok"])
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("read-only"))
        let count = try await db.dbQueue.read { try AgentAction.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }
}
