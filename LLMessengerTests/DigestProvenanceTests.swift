// LLMessengerTests/DigestProvenanceTests.swift
//
// Drives the real BriefEngine and MCPToolbox against an in-memory database to prove
// that a digest records exactly the conversations whose content went into its
// prompt, and that MCP withholds a digest when any of them is Local-only now.
import XCTest
import GRDB
@testable import LLMessenger

/// Cloud-style client (Local-only chats are excluded from prompts) that records every
/// prompt and answers with one valid card per conversation block it was shown.
private final class RecordingLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _briefPrompts: [(system: String, user: String)] = []

    var briefPrompts: [(system: String, user: String)] {
        lock.lock(); defer { lock.unlock() }
        return _briefPrompts
    }

    private func append(system: String, user: String) {
        lock.lock(); defer { lock.unlock() }
        _briefPrompts.append((system, user))
    }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        let system = messages.first { $0.role == .system }?.content ?? ""
        let user = messages.first { $0.role == .user }?.content ?? ""
        if system.contains("2-3 sentences") {
            return LLMResponse(text: "Episodic summary.", inputTokens: 1, outputTokens: 1)
        }
        append(system: system, user: user)

        var cards: [String] = []
        for (service, conversation, firstID) in Self.blocks(in: user) {
            cards.append("""
            {"id": "\(service)-\(conversation)", "service": "\(service)", "conversationId": "\(conversation)",
             "headline": "H \(conversation)", "priority": "medium", "summary": "S \(conversation).",
             "counts": {"messages": 1, "threads": 1, "people": 1},
             "sourceMessageIds": ["\(firstID)"], "actionItems": []}
            """)
        }
        return LLMResponse(text: "{\"cards\": [\(cards.joined(separator: ","))]}", inputTokens: 1, outputTokens: 1)
    }

    /// (service, conversationId, first message id) for every "=== [svc] conv | title ===" block.
    static func blocks(in prompt: String) -> [(String, String, String)] {
        var result: [(String, String, String)] = []
        var current: (String, String)?
        for line in prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("=== ["), let close = line.firstIndex(of: "]"), let pipe = line.range(of: " | ") {
                let service = String(line[line.index(line.startIndex, offsetBy: 5)..<close])
                let conversation = String(line[line.index(close, offsetBy: 2)..<pipe.lowerBound])
                current = (service, conversation)
            } else if let (service, conversation) = current, line.hasPrefix("[id="),
                      let end = line.range(of: " | ") {
                result.append((service, conversation, String(line[line.index(line.startIndex, offsetBy: 4)..<end.lowerBound])))
                current = nil
            }
        }
        return result
    }

    static func conversationKeys(in prompt: String) -> Set<BriefConversationKey> {
        Set(blocks(in: prompt).map { BriefConversationKey(service: $0.0, conversationID: $0.1) })
    }
}

@MainActor
final class DigestProvenanceTests: XCTestCase {

    private final class Flags: @unchecked Sendable {
        var enabledSince: Date? = .distantPast
    }

    private var db: AppDatabase!
    private var client: RecordingLLMClient!
    private var engine: BriefEngine!
    private var toolbox: MCPToolbox!

    override func setUp() async throws {
        try await super.setUp()
        db = try AppDatabase(inMemory: true)
        client = RecordingLLMClient()
        engine = BriefEngine(database: db, client: client, model: "m", basePrompt: "B")
        let db = self.db!
        toolbox = MCPToolbox(
            settings: MCPSettingsReader(isEnabled: { true }, isGlobalLocalOnly: { false },
                                        enabledSince: { .distantPast }),
            openReader: { db }, openWriter: { db })
    }

    // MARK: - Helpers

    private func key(_ conversation: String, service: String = "signal") -> BriefConversationKey {
        BriefConversationKey(service: service, conversationID: conversation)
    }

    private func addMessage(_ conversation: String, id: String, service: String = "signal",
                            text: String = "hello") throws {
        try db.dbQueue.write { d in
            var m = Message(briefId: nil, service: service, conversationId: conversation,
                            conversationName: "Name \(conversation)", messageId: id, sender: "Sender",
                            text: text, timestamp: Date().addingTimeInterval(-60), isSent: false)
            try m.insert(d)
        }
    }

    private func setPrivacy(_ conversation: String, _ value: String, service: String = "signal") throws {
        try db.dbQueue.write { d in
            try ConversationContext(service: service, conversationId: conversation, label: "x",
                                    priorityHint: "auto", updatedAt: Date(),
                                    privacyOverride: value).save(d)
        }
    }

    private func provenance(of briefID: Int64) throws -> BriefProvenance {
        try BriefRepository(database: db).fetchBriefProvenance(briefID: briefID)
    }

    private func servedDigestIDs() throws -> [Int64] {
        let out = toolbox.call(tool: "get_latest_digest", arguments: ["limit": 5])
        XCTAssertFalse(out.isError, out.text)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any])
        let digests = try XCTUnwrap(json["digests"] as? [[String: Any]])
        return digests.compactMap { ($0["id"] as? NSNumber)?.int64Value }
    }

    private func build() async throws -> Int64 {
        let id = try await engine.processNewMessages()
        return try XCTUnwrap(id)
    }

    private func history(_ adapter: FakeMessengerAdapter) async throws -> Int64 {
        let id = try await engine.summarizeLast(hours: 24, adapters: ["signal": adapter])
        return try XCTUnwrap(id)
    }

    // MARK: - Incremental digests

    func testDigestRecordsExactlyTheConversationsInItsPrompt() async throws {
        try addMessage("a", id: "a1")
        try addMessage("b", id: "b1")
        try addMessage("c", id: "c1")
        let briefID = try await build()

        let promptKeys = client.briefPrompts.reduce(into: Set<BriefConversationKey>()) {
            $0.formUnion(RecordingLLMClient.conversationKeys(in: $1.user))
        }
        XCTAssertEqual(promptKeys, [key("a"), key("b"), key("c")], "test premise: all three were prompted")
        let recorded = try provenance(of: briefID)
        XCTAssertEqual(recorded.conversations, promptKeys)
        XCTAssertFalse(recorded.incomplete)
        XCTAssertEqual(try servedDigestIDs(), [briefID])
    }

    func testConversationExcludedByPrivacyAtBuildTimeIsNotRecorded() async throws {
        try addMessage("a", id: "a1")
        try addMessage("secret", id: "s1", text: "top secret text")
        try setPrivacy("secret", "local_only")
        let briefID = try await build()

        XCTAssertFalse(client.briefPrompts.contains { $0.user.contains("top secret text") })
        XCTAssertEqual(try provenance(of: briefID).conversations, [key("a")])
    }

    func testMarkingARecordedConversationLocalOnlyWithholdsTheDigest() async throws {
        try addMessage("a", id: "a1")
        try addMessage("b", id: "b1")
        let briefID = try await build()
        XCTAssertEqual(try servedDigestIDs(), [briefID])

        try setPrivacy("never-in-it", "local_only")
        XCTAssertEqual(try servedDigestIDs(), [briefID], "a conversation outside the prompt does not matter")

        try setPrivacy("b", "local_only")
        XCTAssertEqual(try servedDigestIDs(), [], "b was in the prompt, so any card may quote it")
    }

    func testConversationThatOnlyContributedThroughAnEpisodicSummaryStillCounts() async throws {
        try addMessage("y", id: "y1")
        let first = try await build()

        // The next cycle compresses the first brief into an episodic summary and feeds
        // that summary into the prompt, although "y" has no new messages.
        try addMessage("x", id: "x1")
        let second = try await build()
        XCTAssertTrue(client.briefPrompts.last?.system.contains("Episodic summary.") == true,
                      "test premise: the stored summary is in the second prompt")
        XCTAssertEqual(RecordingLLMClient.conversationKeys(in: client.briefPrompts.last?.user ?? ""), [key("x")])

        let recorded = try provenance(of: second)
        XCTAssertEqual(recorded.conversations, [key("x"), key("y")])
        XCTAssertFalse(recorded.incomplete)
        XCTAssertEqual(Set(try servedDigestIDs()), [first, second])

        try setPrivacy("y", "local_only")
        XCTAssertEqual(try servedDigestIDs(), [], "both digests involve y")
    }

    func testSummaryFromABriefWithoutProvenanceMakesTheDigestIncomplete() async throws {
        // A brief from before provenance existed, already compressed into a summary.
        try await db.dbQueue.write { d in
            var legacy = Brief(createdAt: Date().addingTimeInterval(-3600), status: "ready",
                               services: "[\"signal\"]", openingSummary: nil, notificationText: "old",
                               episodicSummary: "Old summary of unknown chats.")
            try legacy.insert(d)
        }
        try addMessage("x", id: "x1")
        let briefID = try await build()
        XCTAssertTrue(client.briefPrompts.last?.system.contains("Old summary of unknown chats.") == true)

        let recorded = try provenance(of: briefID)
        XCTAssertTrue(recorded.incomplete)
        XCTAssertEqual(recorded.conversations, [key("x")])
        XCTAssertEqual(try servedDigestIDs(), [], "incomplete provenance fails closed")
    }

    func testDigestWithNoProvenanceRowsIsWithheld() async throws {
        try addMessage("a", id: "a1")
        let briefID = try await build()
        XCTAssertEqual(try servedDigestIDs(), [briefID])
        try await db.dbQueue.write { try $0.execute(sql: "DELETE FROM briefProvenance") }
        XCTAssertEqual(try servedDigestIDs(), [])
    }

    // MARK: - History summaries

    private func historyAdapter(_ conversations: [String]) -> FakeMessengerAdapter {
        let adapter = FakeMessengerAdapter(serviceID: "signal")
        for conversation in conversations {
            adapter.addMessage(convId: conversation, convName: "Name \(conversation)", msgId: "\(conversation)-1")
        }
        return adapter
    }

    func testCleanHistorySummaryIsServed() async throws {
        let briefID = try await history(historyAdapter(["h1", "h2"]))
        let promptKeys = RecordingLLMClient.conversationKeys(in: client.briefPrompts.last?.user ?? "")
        XCTAssertEqual(promptKeys, [key("h1"), key("h2")])
        XCTAssertEqual(try provenance(of: briefID).conversations, promptKeys)
        XCTAssertEqual(try servedDigestIDs(), [briefID])
    }

    func testHistorySummaryFedByANowLocalOnlyConversationIsWithheld() async throws {
        let briefID = try await history(historyAdapter(["h1", "h2"]))
        XCTAssertEqual(try servedDigestIDs(), [briefID])
        // Detach the messages, as when a history summary re-reads ones that stay
        // attached to an earlier digest: provenance must carry the decision alone.
        try await db.dbQueue.write { try $0.execute(sql: "UPDATE messages SET briefId = NULL") }
        XCTAssertEqual(try servedDigestIDs(), [briefID])
        try setPrivacy("h2", "local_only")
        XCTAssertEqual(try servedDigestIDs(), [])
    }

    func testHistorySummaryExcludesPrivateConversationAtBuildTime() async throws {
        try setPrivacy("hidden", "local_only")
        let briefID = try await history(historyAdapter(["h1", "hidden"]))
        XCTAssertEqual(try provenance(of: briefID).conversations, [key("h1")])
    }

    func testPriorityCorrectionHeadlinesAreRecordedOrFilteredLikeConversations() async throws {
        try await db.dbQueue.write { d in
            for (conversation, headline) in [("fine", "Headline of fine chat"), ("priv", "Headline of private chat")] {
                var c = PriorityCorrection(id: nil, service: "signal", conversationId: conversation,
                                           cardHeadline: headline, llmPriority: "low", userPriority: "high",
                                           createdAt: Date())
                try c.insert(d)
            }
        }
        try setPrivacy("priv", "local_only")
        let briefID = try await history(historyAdapter(["h1"]))
        let system = try XCTUnwrap(client.briefPrompts.last?.system)
        XCTAssertTrue(system.contains("Headline of fine chat"))
        XCTAssertFalse(system.contains("Headline of private chat"), "a Local-only chat's headline must not reach the prompt")
        XCTAssertEqual(try provenance(of: briefID).conversations, [key("h1"), key("fine")])
    }

    // MARK: - Schema

    func testDeletingABriefRemovesItsProvenance() async throws {
        try addMessage("a", id: "a1")
        let briefID = try await build()
        XCTAssertFalse(try provenance(of: briefID).conversations.isEmpty)
        try await db.dbQueue.write { try $0.execute(sql: "DELETE FROM briefs WHERE id = ?", arguments: [briefID]) }
        XCTAssertEqual(try provenance(of: briefID), BriefProvenance())
    }

    func testMigrationAppliesToADatabaseAtThePreviousSchemaVersion() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-migration-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }

        var old: DatabaseQueue? = try DatabaseQueue(path: url.path)
        try AppDatabase.makeMigrator().migrate(try XCTUnwrap(old), upTo: "v35_canonical_brief_cards")
        try old?.write { d in
            XCTAssertFalse(try d.tableExists("briefProvenance"))
            try d.execute(sql: """
                INSERT INTO briefs (createdAt, status, services, openingSummary, notificationText)
                VALUES (?, 'ready', '["signal"]', NULL, 'legacy')
                """, arguments: [Date()])
        }
        old = nil

        let upgraded = try AppDatabase(path: url.path)
        try upgraded.integrityCheck()
        let legacyID = try upgraded.dbQueue.read { try Int64.fetchOne($0, sql: "SELECT id FROM briefs") }
        let legacy = try XCTUnwrap(legacyID)
        XCTAssertEqual(try BriefRepository(database: upgraded).fetchBriefProvenance(briefID: legacy), BriefProvenance(),
                       "a brief from before the migration has no provenance and is withheld by MCP")
        XCTAssertNotNil(try upgraded.dbQueue.read { try String.fetchOne($0, sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v36_brief_provenance'") })

        try upgraded.dbQueue.write { d in
            try BriefRepository.insertBriefProvenance(
                BriefProvenance(conversations: [BriefConversationKey(service: "signal", conversationID: "a")], incomplete: true),
                briefID: legacy, db: d)
        }
        let stored = try BriefRepository(database: upgraded).fetchBriefProvenance(briefID: legacy)
        XCTAssertEqual(stored.conversations.count, 1)
        XCTAssertTrue(stored.incomplete)
    }

    // MARK: - Second-order: stored state and previous card

    /// An earlier brief with one card for `conversation`, as the prompt's "previous card"
    /// and state. `sources` nil = no provenance rows (a brief from before provenance).
    private func seedEarlierCard(conversation: String, sources: [String]?) async throws {
        try await db.dbQueue.write { d in
            var earlier = Brief(createdAt: Date().addingTimeInterval(-7200), status: "ready", services: "[\"signal\"]",
                                openingSummary: nil, notificationText: "old", episodicSummary: nil)
            try earlier.insert(d)
            let briefID = try XCTUnwrap(earlier.id)
            try BriefCardRecord(id: "signal-\(conversation)-old", briefId: briefID, service: "signal",
                                conversationId: conversation, conversationTitle: nil, headline: "Old headline",
                                priority: "medium", summary: "Old card summary.", actionItems: "[]",
                                callbackText: nil, sourceMessageIds: "[]",
                                createdAt: Date().addingTimeInterval(-7200)).insert(d)
            if let sources {
                let keys = Set(sources.map { BriefConversationKey(service: "signal", conversationID: $0) })
                try BriefRepository.insertBriefProvenance(BriefProvenance(conversations: keys), briefID: briefID, db: d)
            }
        }
    }

    func testPreviousCardFromABriefWithoutProvenanceMakesTheNewDigestIncomplete() async throws {
        try await seedEarlierCard(conversation: "x", sources: nil)
        try addMessage("x", id: "x1")
        let briefID = try await build()

        XCTAssertTrue(client.briefPrompts.last?.user.contains("Old headline") == true,
                      "test premise: the previous card's headline is in the prompt")
        let recorded = try provenance(of: briefID)
        XCTAssertTrue(recorded.incomplete, "the previous card's sources are unknown")
        XCTAssertEqual(try servedDigestIDs(), [], "an incomplete digest is withheld from MCP")
    }

    func testPreviousCardsSourcesAreCountedInTheNewDigest() async throws {
        try addMessage("y", id: "y0")
        try await seedEarlierCard(conversation: "x", sources: ["x", "y"])
        try addMessage("x", id: "x1")
        try setPrivacy("y", "local_only")
        // y is Local-only now and is excluded from this prompt; the old card for x was
        // written while y fed the same digest, so the new digest must reflect that.
        let briefID = try await build()

        let recorded = try provenance(of: briefID)
        XCTAssertFalse(recorded.incomplete)
        XCTAssertTrue(recorded.conversations.contains(key("y")))
        XCTAssertEqual(try servedDigestIDs(), [], "withheld: its history involves a Local-only chat")
    }
}
