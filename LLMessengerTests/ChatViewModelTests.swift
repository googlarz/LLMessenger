// LLMessengerTests/ChatViewModelTests.swift
import XCTest
@testable import LLMessenger

@MainActor
final class ChatViewModelTests: XCTestCase {

    func testLoadBriefPopulatesMessages() async throws {
        let db = try AppDatabase(inMemory: true)
        var briefId: Int64 = 0
        try await db.dbQueue.write { db in
            var b = Brief(createdAt: Date(), status: "ready", services: "[]",
                          openingSummary: "Summary", notificationText: "x",
                          episodicSummary: nil)
            try b.insert(db)
            briefId = b.id!
            var msg = Message(briefId: briefId, service: "telegram",
                              conversationId: "c1", messageId: "m1",
                              sender: "Alice", text: "Hello",
                              timestamp: Date(), isSent: false)
            try msg.insert(db)
        }
        let mock = MockLLMClient()
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)

        try await vm.loadBrief(brief)

        XCTAssertEqual(vm.threadItems.count, 1)
        if case .message(let m) = vm.threadItems[0] {
            XCTAssertEqual(m.text, "Hello")
        } else {
            XCTFail("Expected .message ThreadItem")
        }
    }

    func testSendAddsAssistantResponse() async throws {
        let db = try AppDatabase(inMemory: true)
        var briefId: Int64 = 0
        try await db.dbQueue.write { db in
            var b = Brief(createdAt: Date(), status: "ready", services: "[]",
                          openingSummary: "Summary", notificationText: "x",
                          episodicSummary: nil)
            try b.insert(db)
            briefId = b.id!
            var msg = Message(briefId: briefId, service: "telegram",
                              conversationId: "c1", messageId: "m1",
                              sender: "Alice", text: "Hello",
                              timestamp: Date(), isSent: false)
            try msg.insert(db)
        }
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Alice said hello.", inputTokens: 5, outputTokens: 3)
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)
        vm.inputText = "What did Alice say?"

        await vm.send()

        XCTAssertEqual(mock.calls.count, 1)
        let assistantItems = vm.threadItems.filter {
            if case .assistantResponse = $0 { return true }
            return false
        }
        XCTAssertEqual(assistantItems.count, 1)
        XCTAssertTrue(vm.inputText.isEmpty)
    }

    func testDiscardDraftRemovesItem() async throws {
        let db = try AppDatabase(inMemory: true)
        let mock = MockLLMClient()
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let vm = ChatViewModel(appState: appState)
        let draftID = UUID()
        let draft = ReplyDraft(id: draftID, text: "Draft reply",
                               conversationID: "c1", senderName: "Alice")
        vm.threadItems = [.replyDraft(id: draftID, draft: draft)]

        vm.discardDraft(id: draftID)

        XCTAssertTrue(vm.threadItems.isEmpty)
    }
}
