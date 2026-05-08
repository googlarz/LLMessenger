// LLMessengerTests/PipelineScenarioTests.swift
// Layer 1: Story-based end-to-end tests. Each test names the production failure it guards.
import XCTest
import GRDB
@testable import LLMessenger

// MARK: - DynamicMockLLMClient
//
// Generates structurally valid BriefJSON whose sourceMessageIds match the actual
// message IDs inserted into the DB. This is what BriefEngine validates — making
// every scenario test a real integration test, not a mock-the-implementation test.

final class DynamicMockLLMClient: LLMClient {
    struct Spec {
        let convId: String
        let messageIds: [String]
        let fail: Bool
        let actions: [String]
        init(convId: String, messageIds: [String], fail: Bool = false, actions: [String] = []) {
            self.convId = convId; self.messageIds = messageIds; self.fail = fail; self.actions = actions
        }
    }

    /// Keyed by service name. Missing key → throws (test setup error).
    var specs: [String: Spec] = [:]
    private(set) var callCount = 0

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        callCount += 1
        let sys = messages.first(where: { $0.role == .system })?.content ?? ""

        // Compressor calls arrive with a different prompt mode — return plain text.
        if sys.contains("2-3 sentences") {
            return LLMResponse(text: "Episodic summary.", inputTokens: 5, outputTokens: 5)
        }

        // Detect service from "Connected services: <name>" line only.
        // A naive sys.contains("signal") would false-match on the telegram call because
        // PromptBuilder.suffix embeds "=== [signal] abc123 | Alice ===" as an example in every prompt.
        let connectedLine = sys.split(separator: "\n").first { $0.hasPrefix("Connected services:") }.map(String.init) ?? ""
        let service = ["signal", "telegram", "imessage"].first { connectedLine.contains($0) } ?? "unknown"
        guard let spec = specs[service] else {
            throw NSError(domain: "DynamicMock", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No spec registered for service '\(service)'"])
        }
        if spec.fail {
            throw NSError(domain: "DynamicMock", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "Simulated LLM failure for '\(service)'"])
        }
        return LLMResponse(text: validJSON(service: service, spec: spec), inputTokens: 10, outputTokens: 20)
    }

    private func validJSON(service: String, spec: Spec) -> String {
        let ids = spec.messageIds.map { "\"\($0)\"" }.joined(separator: ", ")
        let acts = spec.actions.map { "\"\($0)\"" }.joined(separator: ", ")
        let cardId = "\(service)-\(spec.convId)-\(spec.messageIds.first ?? UUID().uuidString)"
        return """
        {
          "cards": [{
            "id": "\(cardId)",
            "service": "\(service)",
            "conversationId": "\(spec.convId)",
            "headline": "\(service.capitalized) update",
            "priority": "medium",
            "summary": "Summary for \(spec.convId).",
            "counts": {"messages": \(spec.messageIds.count), "threads": 1, "people": 1},
            "sourceMessageIds": [\(ids)],
            "actionItems": [\(acts)]
          }]
        }
        """
    }
}

// MARK: - PipelineScenarioTests

@MainActor
final class PipelineScenarioTests: XCTestCase {

    // MARK: Helpers

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func insertMessage(db: AppDatabase,
                               service: String,
                               convId: String,
                               convName: String? = nil,
                               messageId: String,
                               sender: String = "Alice",
                               text: String = "Hello",
                               timeOffset: TimeInterval = 0) async throws {
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: service,
                            conversationId: convId, conversationName: convName,
                            messageId: messageId, sender: sender, text: text,
                            timestamp: Date().addingTimeInterval(timeOffset), isSent: false)
            try m.insert(d)
        }
    }

    private func decodeServices(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    // MARK: - Scenario 1: "Alice sends a Signal message, user sees brief, can reply"
    //
    // Guards against: pipeline silently swallowing messages with no brief output.

    func testHappyPathSingleServiceMessageToBriefToUnread() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, service: "signal", convId: "alice-conv",
                                convName: "Alice", messageId: "sig-m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "alice-conv", messageIds: ["sig-m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let rawBriefId = try await engine.processNewMessages()
        let briefId = try XCTUnwrap(rawBriefId, "Pipeline must return a briefId for valid messages")

        // Brief stored as ready with correct service attribution
        let brief = try BriefRepository(database: db).fetchBrief(id: briefId)!
        XCTAssertEqual(brief.briefStatus, .ready)
        XCTAssertTrue(decodeServices(brief.services).contains("signal"))
        XCTAssertNil(brief.failedServices)

        // The source message is attached — it will not be re-processed next cycle
        let attached = try await db.dbQueue.read { d in
            try Message.filter(Column("briefId") == briefId).fetchAll(d)
        }
        XCTAssertEqual(attached.count, 1)
        XCTAssertEqual(attached[0].messageId, "sig-m1")

        // AppState sees exactly 1 unread brief
        let appState = AppState(database: db, llmClient: mock, llmModel: "m", basePrompt: "B")
        appState.refreshBriefs()
        XCTAssertEqual(appState.unreadCount, 1)
    }

    // MARK: - Scenario 2: "Two services both generate cards in one unified brief"
    //
    // Guards against: multi-service TaskGroup producing partial or split briefs.

    func testTwoServicesGenerateTwoCardsInOneBrief() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, service: "signal", convId: "s-conv",
                                messageId: "sig-m1", timeOffset: -10)
        try await insertMessage(db: db, service: "telegram", convId: "t-conv",
                                messageId: "tg-m1", sender: "Bob")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "s-conv", messageIds: ["sig-m1"])
        mock.specs["telegram"] = .init(convId: "t-conv", messageIds: ["tg-m1"])

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let rawBriefId2 = try await engine.processNewMessages()
        let briefId = try XCTUnwrap(rawBriefId2)

        let cards = try BriefRepository(database: db).fetchBriefCards(briefID: briefId)
        XCTAssertEqual(cards.count, 2, "Both services must produce cards in one brief")
        XCTAssertTrue(cards.contains { $0.service == "signal" })
        XCTAssertTrue(cards.contains { $0.service == "telegram" })

        // Only one brief must be stored (not one per service)
        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 1, "All services must share one brief, not produce separate ones")

        let brief = try BriefRepository(database: db).fetchBrief(id: briefId)!
        XCTAssertNil(brief.failedServices)
    }

    // MARK: - Scenario 3: "Inbox is empty — no brief should be created"
    //
    // Guards against: LLM being called or a blank brief stored when there's nothing to process.

    func testNoPendingMessagesProducesNoBrief() async throws {
        let db = try makeDB()
        let mock = DynamicMockLLMClient()
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")

        let result = try await engine.processNewMessages()

        XCTAssertNil(result)
        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 0, "No brief stored when inbox is empty")
        XCTAssertEqual(mock.callCount, 0, "LLM must not be called when inbox is empty")
    }

    // MARK: - Scenario 4: "LLM is down — messages must survive for next cycle"
    //
    // Guards against: attaching messages to a failed brief, losing them forever.

    func testAllServicesFailProducesNoBriefAndMessagesRemainUnattached() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, service: "signal", convId: "s-conv", messageId: "sig-m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "s-conv", messageIds: ["sig-m1"], fail: true)

        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let result = try await engine.processNewMessages()

        XCTAssertNil(result, "All-failure run must return nil — no cards produced")
        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 0, "No brief stored when all LLM calls fail")

        // Messages must still be unattached so the next poll cycle can retry
        let unattached = try BriefRepository(database: db).fetchUnattachedMessages()
        XCTAssertEqual(unattached.count, 1,
                       "Messages must remain unattached on LLM failure — they must survive for retry")
    }

    // MARK: - Scenario 5: "Second poll cycle before brief generation — no duplicates"
    //
    // Guards against: re-processing messages that are already attached to a brief.

    func testAlreadyAttachedMessagesAreNotReprocessedOnSecondRun() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, service: "signal", convId: "s-conv", messageId: "sig-m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "s-conv", messageIds: ["sig-m1"])

        // First run — generates the brief, attaches the message
        let engine1 = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try await engine1.processNewMessages()

        let countAfterFirst = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(countAfterFirst, 1)

        // Second run — no unattached messages remain
        let engine2 = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        let secondResult = try await engine2.processNewMessages()

        XCTAssertNil(secondResult, "Second run must be a no-op when all messages are already processed")
        let countAfterSecond = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(countAfterSecond, 1, "No duplicate brief must be created on second run")
    }

    // MARK: - Scenario 6: "briefingInFlight guard prevents concurrent double-runs"
    //
    // Guards against: two rapid-fire calls to processNewMessages on the same engine instance.

    func testConcurrentProcessNewMessagesIsIdempotent() async throws {
        let db = try makeDB()
        try await insertMessage(db: db, service: "signal", convId: "s-conv", messageId: "sig-m1")

        let mock = DynamicMockLLMClient()
        mock.specs["signal"] = .init(convId: "s-conv", messageIds: ["sig-m1"])

        // Both calls on the same engine — second must be a no-op due to briefingInFlight guard
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        async let first = engine.processNewMessages()
        async let second = engine.processNewMessages()
        let (r1, r2) = try await (first, second)

        // Exactly one must succeed; the other is blocked by the in-flight guard
        let successCount = [r1, r2].compactMap { $0 }.count
        XCTAssertEqual(successCount, 1, "Concurrent calls must produce exactly one brief")

        let briefCount = try await db.dbQueue.read { d in try Brief.fetchCount(d) }
        XCTAssertEqual(briefCount, 1, "briefingInFlight guard must prevent duplicate briefs")
    }
}
