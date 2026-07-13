// LLMessengerTests/DeepIntegrationTests.swift
import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class DeepIntegrationTests: XCTestCase {
    
    private func setupDB() throws -> AppDatabase {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            try ServiceConfig.default(for: "signal").insert(db)
            try ServiceConfig.default(for: "telegram").insert(db)
            try ServiceConfig.default(for: "imessage").insert(db)
        }
        return db
    }

    /// Scenario: Multi-service run where one service fails and one succeeds.
    /// Verify: Parallelization doesn't crash, failed services are tracked, 
    /// and unresolved actions carry forward.
    func testMultiServiceParallelRunScenario() async throws {
        let db = try setupDB()
        let repo = BriefRepository(database: db)
        
        // 1. Prepare previous state with unresolved actions for Signal
        try await db.dbQueue.write { db in
            let state = ConversationState(
                service: "signal",
                conversationId: "s1",
                lastSeenMessageId: "m-old",
                lastSummarizedMessageId: "m-old",
                rollingSummary: "Old Signal summary",
                unresolvedActions: #"["Send invoice"]"#,
                updatedAt: Date()
            )
            try state.insert(db)
        }
        
        // 2. Insert new messages for Signal and Telegram
        try await db.dbQueue.write { db in
            var m1 = Message(briefId: nil, service: "signal", conversationId: "s1",
                              messageId: "m-new-s", sender: "Alice", text: "New Signal message",
                              timestamp: Date(), isSent: false)
            try m1.insert(db)
            
            var m2 = Message(briefId: nil, service: "telegram", conversationId: "t1",
                              messageId: "m-new-t", sender: "Bob", text: "New Telegram message",
                              timestamp: Date(), isSent: false)
            try m2.insert(db)
        }
        
        // 3. Setup mock LLM with partial failure
        // We expect 2 calls: one for Signal (success), one for Telegram (fail)
        let mock = PartialFailureMockLLMClient()
        mock.responses["signal"] = .success(LLMResponse(text: signalSuccessJSON, inputTokens: 10, outputTokens: 5))
        mock.responses["telegram"] = .failure(NSError(domain: "test", code: 500))
        
        let engine = BriefEngine(database: db, client: mock, model: "test", basePrompt: "BASE")
        
        // 4. Run summarization
        let briefID = try await engine.processNewMessages()
        
        // 5. Verify results
        XCTAssertNotNil(briefID)
        let brief = try repo.fetchBrief(id: briefID!)!
        
        // Check service tracking
        let services = try XCTUnwrap(brief.services.data(using: .utf8).flatMap { try JSONDecoder().decode([String].self, from: $0) })
        let failed = try XCTUnwrap(brief.failedServices?.data(using: .utf8).flatMap { try JSONDecoder().decode([String].self, from: $0) })
        
        XCTAssertTrue(services.contains("signal"))
        XCTAssertFalse(services.contains("telegram"))
        XCTAssertTrue(failed.contains("telegram"))
        
        // Check cards
        let cards = try repo.fetchBriefCards(briefID: briefID!)
        XCTAssertEqual(cards.count, 1) // Only signal succeeded
        XCTAssertEqual(cards[0].service, "signal")
        // Card ID is a generated UUID, not the LLM-produced ID
        XCTAssertFalse(cards[0].id.isEmpty)

        // Check sources
        let sources = try repo.fetchSourcesWithMessages(briefCardID: cards[0].id)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].source.messageId, "m-new-s")
        XCTAssertEqual(sources[0].message?.text, "New Signal message")
        
        // Verify continuity: Did Signal prompt include unresolved actions?
        let signalCall = mock.calls.first { $0.messages.last?.content.contains("New Signal message") ?? false }
        XCTAssertNotNil(signalCall)
        XCTAssertTrue(signalCall?.messages.last?.content.contains("Unresolved actions from prior brief: [\"Send invoice\"]") ?? false)

        let partialJob = try XCTUnwrap(repo.fetchBriefJobs().first)
        XCTAssertEqual(partialJob.jobStatus, .partial)
        XCTAssertEqual(try repo.fetchBriefJobMessages(jobID: try XCTUnwrap(partialJob.id)).map(\.messageStatus),
                       [.succeeded, .pending])

        // Retry only the failed Telegram subset. The already-briefed Signal
        // message must not be sent to the model or create a duplicate card.
        mock.responses["telegram"] = .success(
            LLMResponse(text: telegramSuccessJSON, inputTokens: 10, outputTokens: 5)
        )
        let retryBriefID = try await engine.processNewMessages()
        XCTAssertNotNil(retryBriefID)
        let generationCalls = mock.calls.filter { $0.messages.last?.content.contains("=== [") == true }
        XCTAssertEqual(generationCalls.count, 3)
        let retryPrompt = try XCTUnwrap(mock.calls.last?.messages.last?.content)
        XCTAssertTrue(retryPrompt.contains("New Telegram message"))
        XCTAssertFalse(retryPrompt.contains("New Signal message"))

        let completedJob = try XCTUnwrap(repo.fetchBriefJobs().first)
        XCTAssertEqual(completedJob.id, partialJob.id)
        XCTAssertEqual(completedJob.jobStatus, .succeeded)
        XCTAssertEqual(completedJob.attemptCount, 2)
    }
}

// MARK: - Mocks & Data

private let signalSuccessJSON = """
{
  "total_messages": 1,
  "total_threads": 1,
  "total_people": 1,
  "cards": [
    {
      "id": "signal-s1-1",
      "service": "signal",
      "conversationId": "s1",
      "conversationTitle": "Alice",
      "headline": "Invoice discussion",
      "priority": "high",
      "counts": {"messages": 1, "threads": 1, "people": 1},
      "summary": "Alice is waiting for the invoice.",
      "callback": null,
      "actionItems": ["Send invoice to Alice"],
      "quotes": [],
      "sourceMessageIds": ["m-new-s"]
    }
  ]
}
"""

private let telegramSuccessJSON = """
{
  "total_messages": 1,
  "total_threads": 1,
  "total_people": 1,
  "cards": [
    {
      "id": "telegram-t1-1",
      "service": "telegram",
      "conversationId": "t1",
      "conversationTitle": "Bob",
      "headline": "Telegram follow-up",
      "priority": "medium",
      "counts": {"messages": 1, "threads": 1, "people": 1},
      "summary": "Bob sent a Telegram follow-up.",
      "callback": null,
      "actionItems": [],
      "quotes": [],
      "sourceMessageIds": ["m-new-t"]
    }
  ]
}
"""

final class PartialFailureMockLLMClient: LLMClient {
    var calls: [(model: String, messages: [LLMMessage], maxTokens: Int)] = []
    var responses: [String: Result<LLMResponse, Error>] = [:]
    
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        calls.append((model, messages, maxTokens))
        
        // Hack: identify service by looking for it in the system prompt
        let systemPrompt = messages.first { $0.role == .system }?.content ?? ""
        let service = ["signal", "telegram", "imessage"].first {
            systemPrompt.contains("Connected services: \($0)")
        } ?? "unknown"
        
        if let result = responses[service] {
            switch result {
            case .success(let res): return res
            case .failure(let err): throw err
            }
        }
        throw NSError(domain: "Mock", code: 404, userInfo: [NSLocalizedDescriptionKey: "No mock for \(service)"])
    }
}
