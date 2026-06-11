// LLMessengerTests/ComponentContractTests.swift
// Layer 3: Component contract tests — verifies that seams between components are compatible.
// These tests don't check component internals; they check that component A's output
// is fully consumable by component B, exposing integration bugs invisible to unit tests.
import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class ComponentContractTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    /// Runs the full pipeline for one service and returns the briefId.
    private func runPipeline(db: AppDatabase,
                             service: String,
                             convId: String,
                             convName: String,
                             messageIds: [String]) async throws -> Int64 {
        for (i, mid) in messageIds.enumerated() {
            try await db.dbQueue.write { d in
                var m = Message(briefId: nil, service: service,
                                conversationId: convId, conversationName: convName,
                                messageId: mid, sender: "Sender",
                                text: "Text \(i)",
                                timestamp: Date().addingTimeInterval(Double(i)),
                                isSent: false)
                try m.insert(d)
            }
        }
        let mock = DynamicMockLLMClient()
        mock.specs[service] = .init(convId: convId, messageIds: messageIds)
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()
        return try XCTUnwrap(result,
                             "runPipeline: engine must produce a brief for contract tests to be meaningful")
    }

    // MARK: - Contract 1: BriefEngine → ChatViewModel
    //
    // Guards against: ChatViewModel failing to load a real brief produced by BriefEngine.
    // If BriefEngine changes its schema and ChatViewModel's loadBrief breaks silently, this catches it.

    func testBriefEngineOutputIsFullyNavigableByChatViewModel() async throws {
        let db = try makeDB()
        let briefId = try await runPipeline(db: db, service: "signal", convId: "c1",
                                            convName: "Alice", messageIds: ["m1", "m2"])

        let repo = BriefRepository(database: db)
        let brief = try XCTUnwrap(repo.fetchBrief(id: briefId),
                                  "Contract: BriefEngine must store a fetchable brief")

        let appState = AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "B")
        let vm = ChatViewModel(appState: appState)

        // loadBrief must not throw and must populate briefConvs from the engine's messages
        try await vm.loadBrief(brief)

        XCTAssertFalse(vm.briefConvs.isEmpty,
                       "Contract: ChatViewModel.briefConvs must be populated from BriefEngine output")
        XCTAssertTrue(vm.briefConvs.contains { $0.convId == "c1" },
                      "Contract: briefConvs must contain the conversation produced by BriefEngine")
    }

    // MARK: - Contract 2: BriefEngine → AppState.unreadCount
    //
    // Guards against: AppState.unreadCount not reflecting brief pipeline output.
    // A mismatch here means the user would see "0 new" even though briefs were generated.

    func testAppStateUnreadCountReflectsPipelineOutput() async throws {
        let db = try makeDB()

        // Run pipeline twice (two separate sets of messages → two briefs)
        _ = try await runPipeline(db: db, service: "signal", convId: "c1",
                                  convName: "Alice", messageIds: ["m1"])
        _ = try await runPipeline(db: db, service: "telegram", convId: "c2",
                                  convName: "Bob", messageIds: ["m2"])

        let appState = AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "B")
        await appState.refreshBriefs().value

        XCTAssertEqual(appState.unreadCount, 2,
                       "Contract: AppState.unreadCount must equal the number of ready briefs produced by BriefEngine")
    }

    // MARK: - Contract 3: AppState.markAsOpen → unreadCount
    //
    // Guards against: markAsOpen failing to write through to AppState.unreadCount.
    // If markAsOpen updates the DB but AppState doesn't refresh, the badge stays stale.

    func testMarkAsOpenDecrementsUnreadCount() async throws {
        let db = try makeDB()
        let briefId = try await runPipeline(db: db, service: "signal", convId: "c1",
                                            convName: "Alice", messageIds: ["m1"])

        let appState = AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "B")
        await appState.refreshBriefs().value
        XCTAssertEqual(appState.unreadCount, 1, "Pre-condition: one ready brief")

        await appState.markAsOpen(briefID: briefId).value

        XCTAssertEqual(appState.unreadCount, 0,
                       "Contract: markAsOpen must decrement unreadCount — the badge must clear when the brief is opened")
        XCTAssertEqual(appState.briefs.first?.briefStatus, .open,
                       "Contract: brief status must be .open after markAsOpen")
    }

    // MARK: - Contract 4: sourceMessageIds → ChatViewModel.briefConvs
    //
    // Guards against: a card referencing messages that ChatViewModel can't find in briefConvs.
    // If this breaks, tapping a card would show an empty conversation list.

    func testSourceMessageIdsLinkToConversationsLoadableInChatViewModel() async throws {
        let db = try makeDB()
        let briefId = try await runPipeline(db: db, service: "signal", convId: "alice-conv",
                                            convName: "Alice Johnson", messageIds: ["m1", "m2"])

        // Extract the conversationIds mentioned in card sourceMessageIds
        let cards = try BriefRepository(database: db).fetchBriefCards(briefID: briefId)
        let sourceIds = cards.flatMap { card -> [String] in
            (try? JSONDecoder().decode([String].self, from: Data(card.sourceMessageIds.utf8))) ?? []
        }
        let sourceMessages = try await db.dbQueue.read { d in
            try Message.filter(sourceIds.contains(Column("messageId"))).fetchAll(d)
        }
        let sourceConvIds = Set(sourceMessages.map(\.conversationId))

        // Load the brief into ChatViewModel and check briefConvs covers those convIds
        let repo = BriefRepository(database: db)
        let brief = try XCTUnwrap(repo.fetchBrief(id: briefId))

        let appState = AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "B")
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)

        let vmConvIds = Set(vm.briefConvs.map(\.convId))
        for convId in sourceConvIds {
            XCTAssertTrue(vmConvIds.contains(convId),
                          "Contract: sourceMessageId's conversation '\(convId)' must appear in ChatViewModel.briefConvs")
        }
    }
}
