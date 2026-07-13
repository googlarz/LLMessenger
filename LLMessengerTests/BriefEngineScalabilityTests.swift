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

        let briefIDs = try await engine.processNewMessageBatch()

        XCTAssertEqual(client.generationPrompts.count, BriefEngine.maximumAutomaticJobsPerRun)
        XCTAssertEqual(briefIDs.count, BriefEngine.maximumAutomaticJobsPerRun)
        XCTAssertFalse(try BriefRepository(database: database).fetchUnattachedMessages().isEmpty)
    }

    func testBulkPromptDataUsesConstantQueryCount() throws {
        let database = try makeDatabase()
        let repository = BriefRepository(database: database)
        let now = Date()
        var requests: [BriefPromptRequest] = []

        try database.dbQueue.write { db in
            var brief = Brief(
                createdAt: now.addingTimeInterval(-300),
                status: BriefStatus.ready.rawValue,
                services: #"["telegram"]"#,
                notificationText: "Earlier brief"
            )
            try brief.insert(db)
            let briefID = try XCTUnwrap(brief.id)

            for index in 0..<40 {
                let conversationID = "conversation-\(index)"
                let before = now.addingTimeInterval(Double(index))
                let context = ConversationContext(
                    service: "telegram",
                    conversationId: conversationID,
                    label: "Contact \(index)",
                    priorityHint: "auto",
                    updatedAt: now
                )
                try context.insert(db)
                try ConversationState(
                    service: "telegram",
                    conversationId: conversationID,
                    lastSeenMessageId: "old-\(index)",
                    lastSummarizedMessageId: "old-\(index)",
                    rollingSummary: "Earlier summary \(index)",
                    participants: nil,
                    knownEntities: nil,
                    unresolvedActions: nil,
                    lastBriefCardId: "card-\(index)",
                    prioritySignals: nil,
                    sourceMessageIds: nil,
                    updatedAt: now
                ).insert(db)
                try BriefCardRecord(
                    id: "card-\(index)",
                    briefId: briefID,
                    service: "telegram",
                    conversationId: conversationID,
                    conversationTitle: conversationID,
                    headline: "Earlier headline \(index)",
                    priority: "low",
                    summary: "Earlier summary \(index)",
                    actionItems: "[]",
                    callbackText: nil,
                    sourceMessageIds: #"["old"]"#,
                    createdAt: now
                ).insert(db)
                var message = Message(
                    briefId: briefID,
                    service: "telegram",
                    conversationId: conversationID,
                    messageId: "old-\(index)",
                    sender: "Sender",
                    text: "Earlier context",
                    timestamp: before.addingTimeInterval(-60),
                    isSent: false
                )
                try message.insert(db)
                requests.append(BriefPromptRequest(
                    service: "telegram",
                    conversationID: conversationID,
                    before: before,
                    since: before.addingTimeInterval(-3_600),
                    recentMessageLimit: 20
                ))
            }
        }

        var selectCount = 0
        database.dbQueue.writeWithoutTransaction { db in
            db.trace { event in
                if case let .statement(statement) = event,
                   statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased().hasPrefix("SELECT") {
                    selectCount += 1
                }
            }
        }
        let promptData = try repository.fetchBriefPromptData(for: requests)
        database.dbQueue.writeWithoutTransaction { db in db.trace(options: []) }

        XCTAssertLessThanOrEqual(selectCount, 4)
        XCTAssertEqual(promptData.contexts.count, 40)
        XCTAssertEqual(promptData.states.count, 40)
        XCTAssertEqual(promptData.previousCards.count, 40)
        XCTAssertEqual(promptData.recentMessages.count, 40)
        XCTAssertTrue(promptData.recentMessages.values.allSatisfy { $0.count == 1 })
    }

    func testConversationContextBulkFetchHandlesMoreThanSQLiteExpressionDepth() throws {
        let database = try makeDatabase()
        let repository = BriefRepository(database: database)
        let keys = (0..<1_100).map {
            BriefConversationKey(service: "telegram", conversationID: "large-inbox-\($0)")
        }

        try database.dbQueue.write { db in
            for key in keys {
                try ConversationContext(
                    service: key.service,
                    conversationId: key.conversationID,
                    label: key.conversationID,
                    priorityHint: "auto",
                    updatedAt: Date()
                ).insert(db)
            }
        }

        let contexts = try repository.fetchConversationContexts(for: keys)

        XCTAssertEqual(contexts.count, keys.count)
    }

    func testManualSummaryOnlyAttachesCoveredPromptConversations() async throws {
        let database = try makeDatabase()
        try insertMessage(database, conversationID: "covered", messageID: "manual-covered")
        try insertMessage(database, conversationID: "omitted", messageID: "manual-omitted")
        let client = PromptReflectingBriefClient()
        client.omittedConversations = ["omitted"]
        let engine = BriefEngine(database: database, client: client, model: "test", basePrompt: "BASE")

        _ = try await engine.summarizeLast(hours: 24, adapters: [:])

        let messages = try await database.dbQueue.read { db in
            try Message.order(Column("messageId")).fetchAll(db)
        }
        XCTAssertNotNil(messages.first { $0.messageId == "manual-covered" }?.briefId)
        XCTAssertNil(messages.first { $0.messageId == "manual-omitted" }?.briefId)
    }

    func testManualSummaryRespectsGlobalPromptBudgetAndLeavesOverflowUnattached() async throws {
        let database = try makeDatabase()
        let largeText = String(repeating: "abcdefghij", count: 500)
        for index in 0..<24 {
            try insertMessage(
                database,
                conversationID: "manual-large-\(index)",
                messageID: "manual-large-message-\(index)",
                text: largeText,
                timestamp: Date().addingTimeInterval(Double(index))
            )
        }
        let client = PromptReflectingBriefClient()
        let engine = BriefEngine(database: database, client: client, model: "test", basePrompt: "BASE")

        _ = try await engine.summarizeLast(hours: 24, adapters: [:])

        let prompt = try XCTUnwrap(client.generationPrompts.first)
        XCTAssertLessThanOrEqual(
            TokenEstimator.estimate(prompt),
            BriefEngine.maximumAutomaticUserPromptTokens
        )
        let attachedIDs = try await database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT messageId FROM messages WHERE briefId IS NOT NULL")
        }
        XCTAssertEqual(Set(attachedIDs), client.promptedMessageIDs)
        XCTAssertFalse(try BriefRepository(database: database).fetchUnattachedMessages().isEmpty)
    }

    func testOversizedSingleMessageMakesProgressWithinPromptBudget() async throws {
        let database = try makeDatabase()
        try insertMessage(
            database,
            conversationID: "oversized",
            messageID: "oversized-message",
            text: String(repeating: "0123456789", count: 20_000)
        )
        let client = PromptReflectingBriefClient()
        let engine = BriefEngine(database: database, client: client, model: "test", basePrompt: "BASE")

        let briefID = try await engine.processNewMessages()

        XCTAssertNotNil(briefID)
        let prompt = try XCTUnwrap(client.generationPrompts.first)
        XCTAssertLessThanOrEqual(
            TokenEstimator.estimate(prompt),
            BriefEngine.maximumAutomaticUserPromptTokens
        )
        let stored = try await database.dbQueue.read { db in
            try Message.filter(Column("messageId") == "oversized-message").fetchOne(db)
        }
        XCTAssertNotNil(stored?.briefId)
    }

    func testServiceScopedUnattachedFetchIsLimitedAndOldestFirst() throws {
        let database = try makeDatabase()
        let start = Date()
        for index in 0..<25 {
            try insertMessage(
                database,
                conversationID: "limited",
                messageID: "limited-\(index)",
                timestamp: start.addingTimeInterval(Double(index))
            )
        }

        let messages = try BriefRepository(database: database).fetchUnattachedMessages(
            service: "telegram",
            since: start.addingTimeInterval(-1),
            limit: 10
        )

        XCTAssertEqual(messages.count, 10)
        XCTAssertEqual(messages.map(\.messageId), (0..<10).map { "limited-\($0)" })
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
