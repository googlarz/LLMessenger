// LLMessengerTests/MemoryCompressorTests.swift
import XCTest
@testable import LLMessenger

final class MockLLMClient: LLMClient {
    var calls: [(model: String, messages: [LLMMessage], maxTokens: Int)] = []
    var response: LLMResponse = LLMResponse(text: "compressed summary", inputTokens: 10, outputTokens: 5)
    var error: Error?

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        calls.append((model, messages, maxTokens))
        if let error { throw error }
        return response
    }
}

@MainActor
final class MemoryCompressorTests: XCTestCase {

    func testCompressFillsEpisodicSummary() async throws {
        let db = try AppDatabase(inMemory: true)
        let briefId = try await db.dbQueue.write { db in
            var b = Brief(createdAt: Date(), status: "idle", services: "[]",
                          openingSummary: "Today", notificationText: "x",
                          episodicSummary: nil)
            try b.insert(db)
            let briefId = b.id!
            var msg = Message(briefId: briefId, service: "telegram",
                              conversationId: "c1", messageId: "m1",
                              sender: "Alice", text: "Hello",
                              timestamp: Date(), isSent: false)
            try msg.insert(db)
            return briefId
        }

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Alice said hello.", inputTokens: 5, outputTokens: 3)
        let repo = BriefRepository(database: db)
        let compressor = MemoryCompressor(client: mock, model: "test-model", basePrompt: "BASE")

        try await compressor.compress(briefID: briefId, repository: repo)

        let updated = try repo.fetchBrief(id: briefId)
        XCTAssertEqual(updated?.episodicSummary, "Alice said hello.")
        XCTAssertEqual(mock.calls.count, 1)
    }

    func testCompressSkipsBriefWithExistingSummary() async throws {
        let db = try AppDatabase(inMemory: true)
        let briefId = try await db.dbQueue.write { db in
            var b = Brief(createdAt: Date(), status: "idle", services: "[]",
                          openingSummary: nil, notificationText: "x",
                          episodicSummary: "already done")
            try b.insert(db)
            return b.id!
        }

        let mock = MockLLMClient()
        let repo = BriefRepository(database: db)
        let compressor = MemoryCompressor(client: mock, model: "test-model", basePrompt: "BASE")

        try await compressor.compress(briefID: briefId, repository: repo)

        XCTAssertEqual(mock.calls.count, 0)
    }
}
