import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class BriefEngineScalabilityTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(inMemory: true)
    }

    @discardableResult
    private func insertMessage(
        _ database: AppDatabase,
        service: String = "telegram",
        conversationID: String,
        messageID: String,
        text: String = "hello",
        timestamp: Date = Date()
    ) throws -> Message {
        try database.dbQueue.write { db in
            var message = Message(
                briefId: nil,
                service: service,
                conversationId: conversationID,
                messageId: messageID,
                sender: "Sender",
                text: text,
                timestamp: timestamp,
                isSent: false
            )
            try message.insert(db)
            return message
        }
    }

    func testOnlyMessagesFromCoveredPromptConversationsAreAttached() async throws {
        let database = try makeDatabase()
        try insertMessage(database, conversationID: "covered", messageID: "covered-id")
        try insertMessage(database, conversationID: "omitted", messageID: "omitted-id")
        let client = PromptReflectingBriefClient()
        client.omittedConversations = ["omitted"]
        let engine = BriefEngine(database: database, client: client, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        let messages = try await database.dbQueue.read { db in
            try Message.order(Column("messageId")).fetchAll(db)
        }
        XCTAssertNotNil(messages.first { $0.messageId == "covered-id" }?.briefId)
        XCTAssertNil(messages.first { $0.messageId == "omitted-id" }?.briefId)
        let job = try XCTUnwrap(BriefRepository(database: database).fetchBriefJobs().first)
        XCTAssertEqual(job.jobStatus, .partial)
    }

    func testCardCannotCoverConversationUsingAnotherConversationsSource() async throws {
        let database = try makeDatabase()
        try insertMessage(database, conversationID: "first", messageID: "first-id")
        try insertMessage(database, conversationID: "second", messageID: "second-id")
        let client = PromptReflectingBriefClient()
        client.omittedConversations = ["second"]
        client.sourceMessageIDsByConversation["first"] = ["second-id"]
        let engine = BriefEngine(database: database, client: client, model: "test", basePrompt: "BASE")

        let briefID = try await engine.processNewMessages()

        XCTAssertNil(briefID)
        let attachedCount = try await database.dbQueue.read { db in
            try Message.filter(Column("briefId") != nil).fetchCount(db)
        }
        XCTAssertEqual(attachedCount, 0)
    }

    func testMoreThanThirtyConversationsNeverAttachUnpromptedMessages() async throws {
        let database = try makeDatabase()
        let start = Date()
        for index in 0..<31 {
            try insertMessage(
                database,
                conversationID: "conversation-\(index)",
                messageID: "message-\(index)",
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
        let client = PromptReflectingBriefClient()
        let engine = BriefEngine(database: database, client: client, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        let attachedIDs = try await database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT messageId FROM messages WHERE briefId IS NOT NULL")
        }
        XCTAssertEqual(Set(attachedIDs), client.promptedMessageIDs)
        XCTAssertEqual(attachedIDs.count, 31)
    }

    func testAutomaticPromptsRespectGlobalTokenBudget() async throws {
        let database = try makeDatabase()
        let largeText = String(repeating: "abcdefghij", count: 500)
        for index in 0..<24 {
            try insertMessage(
                database,
                conversationID: "large-\(index)",
                messageID: "large-message-\(index)",
                text: largeText
            )
        }
        let client = PromptReflectingBriefClient()
        let engine = BriefEngine(database: database, client: client, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        XCTAssertGreaterThan(client.generationPrompts.count, 1)
        XCTAssertTrue(client.generationPrompts.allSatisfy {
            TokenEstimator.estimate($0) <= BriefEngine.maximumAutomaticUserPromptTokens
        })
    }

    func testAutomaticDrainStopsAtConfiguredJobLimit() async throws {
        let database = try makeDatabase()
        try insertMessage(database, conversationID: "initial", messageID: "initial-id")
        let client = PromptReflectingBriefClient()
        client.onGeneration = { generation in
            guard generation <= BriefEngine.maximumAutomaticJobsPerRun + 2 else { return }
            try? database.dbQueue.write { db in
                var message = Message(
                    briefId: nil,
                    service: "telegram",
                    conversationId: "arrival-\(generation)",
                    messageId: "arrival-id-\(generation)",
                    sender: "Sender",
                    text: "arrived while summarizing",
                    timestamp: Date().addingTimeInterval(Double(generation)),
                    isSent: false
                )
                try message.insert(db)
            }
        }
        let engine = BriefEngine(database: database, client: client, model: "test", basePrompt: "BASE")

        _ = try await engine.processNewMessages()

        XCTAssertEqual(client.generationPrompts.count, BriefEngine.maximumAutomaticJobsPerRun)
        XCTAssertFalse(try BriefRepository(database: database).fetchUnattachedMessages().isEmpty)
    }
}

final class PromptReflectingBriefClient: LLMClient {
    var omittedConversations: Set<String> = []
    var sourceMessageIDsByConversation: [String: [String]] = [:]
    var onGeneration: ((Int) -> Void)?
    private(set) var generationPrompts: [String] = []

    var promptedMessageIDs: Set<String> {
        Set(generationPrompts.flatMap(Self.parsePrompt).flatMap(\.messageIDs))
    }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        let system = messages.first { $0.role == .system }?.content ?? ""
        if system.contains("2-3 sentences") {
            return LLMResponse(text: "Compressed memory.", inputTokens: 1, outputTokens: 1)
        }

        let prompt = messages.last { $0.role == .user }?.content ?? ""
        generationPrompts.append(prompt)
        onGeneration?(generationPrompts.count)
        let conversations = Self.parsePrompt(prompt).filter {
            !omittedConversations.contains($0.conversationID) && !$0.messageIDs.isEmpty
        }
        let cards: [[String: Any]] = conversations.map { conversation in
            [
                "id": "\(conversation.service)-\(conversation.conversationID)",
                "service": conversation.service,
                "conversationId": conversation.conversationID,
                "conversationTitle": conversation.conversationID,
                "headline": "Update for \(conversation.conversationID)",
                "priority": "medium",
                "counts": ["messages": conversation.messageIDs.count, "threads": 1, "people": 1],
                "summary": "Summary for \(conversation.conversationID).",
                "actionItems": [],
                "quotes": [],
                "sourceMessageIds": sourceMessageIDsByConversation[conversation.conversationID]
                    ?? conversation.messageIDs
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["cards": cards], options: [.sortedKeys])
        return LLMResponse(text: String(decoding: data, as: UTF8.self), inputTokens: 1, outputTokens: 1)
    }

    private struct PromptConversation {
        var service: String
        var conversationID: String
        var messageIDs: [String]
    }

    private static func parsePrompt(_ prompt: String) -> [PromptConversation] {
        var conversations: [PromptConversation] = []
        for line in prompt.split(separator: "\n").map(String.init) {
            if line.hasPrefix("=== ["),
               let serviceEnd = line.range(of: "] "),
               let conversationEnd = line.range(of: " |", range: serviceEnd.upperBound..<line.endIndex) {
                let serviceStart = line.index(line.startIndex, offsetBy: 5)
                conversations.append(PromptConversation(
                    service: String(line[serviceStart..<serviceEnd.lowerBound]),
                    conversationID: String(line[serviceEnd.upperBound..<conversationEnd.lowerBound]),
                    messageIDs: []
                ))
            } else if line.hasPrefix("[id="),
                      let idEnd = line.range(of: " |"),
                      !conversations.isEmpty {
                let idStart = line.index(line.startIndex, offsetBy: 4)
                conversations[conversations.count - 1].messageIDs.append(String(line[idStart..<idEnd.lowerBound]))
            }
        }
        return conversations
    }
}
