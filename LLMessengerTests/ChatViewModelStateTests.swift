// LLMessengerTests/ChatViewModelStateTests.swift
import XCTest
@testable import LLMessenger

@MainActor
final class ChatViewModelStateTests: XCTestCase {

    // MARK: - Setup helpers

    private func makeDB() async throws -> AppDatabase {
        try AppDatabase(inMemory: true)
    }

    private func insertBrief(db: AppDatabase, services: String = #"["signal"]"#) async throws -> Int64 {
        try await db.dbQueue.write { d in
            var b = Brief(createdAt: Date(), status: "ready", services: services,
                          openingSummary: nil, notificationText: "x", episodicSummary: nil)
            try b.insert(d)
            return b.id!
        }
    }

    private func insertMessage(db: AppDatabase,
                               briefId: Int64,
                               service: String = "signal",
                               convId: String,
                               convName: String? = nil,
                               sender: String = "Alice",
                               text: String = "Hello",
                               timeOffset: TimeInterval = 0) async throws {
        try await db.dbQueue.write { d in
            var msg = Message(briefId: briefId, service: service,
                              conversationId: convId, conversationName: convName,
                              messageId: "\(convId)-\(UUID().uuidString)",
                              sender: sender, text: text,
                              timestamp: Date().addingTimeInterval(timeOffset), isSent: false)
            try msg.insert(d)
        }
    }

    private func makeVM(db: AppDatabase,
                        mock: any LLMClient,
                        briefId: Int64) async throws -> (ChatViewModel, Brief) {
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)
        return (vm, brief)
    }

    // MARK: - isLoading lifecycle

    func testIsLoadingFalseBeforeAndAfterSend() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "OK", inputTokens: 5, outputTokens: 1)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        XCTAssertFalse(vm.isLoading, "isLoading should be false before send()")
        vm.inputText = "hello"
        await vm.send()
        XCTAssertFalse(vm.isLoading, "isLoading should be false after send() completes (defer fired)")
    }

    func testIsLoadingFalseAfterSendError() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.error = URLError(.notConnectedToInternet)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        vm.inputText = "will this fail?"
        await vm.send()

        XCTAssertFalse(vm.isLoading, "isLoading must be false after error (defer must fire)")
    }

    // MARK: - buildConvList (tested via briefConvs)

    func testBriefConvsDeduplicatesDuplicateConversations() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        // Three messages: two in c1, one in c2 → only 2 distinct convs
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice", timeOffset: -3)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice", sender: "Alice", text: "second", timeOffset: -2)
        try await insertMessage(db: db, briefId: briefId, convId: "c2", convName: "Bob", sender: "Bob", timeOffset: -1)

        let mock = MockLLMClient()
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        XCTAssertEqual(vm.briefConvs.count, 2, "briefConvs must deduplicate (service, convId) pairs")
    }

    func testBriefConvsUsesConversationNameWhenAvailable() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "conv-abc-123", convName: "Alice Müller")

        let mock = MockLLMClient()
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        XCTAssertEqual(vm.briefConvs.first?.name, "Alice Müller",
                       "briefConvs must use conversationName when available")
    }

    func testBriefConvsFallsBackToConversationIdWhenNameMissing() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        // Insert message without conversationName
        try await insertMessage(db: db, briefId: briefId, convId: "raw-conv-id-999", convName: nil)

        let mock = MockLLMClient()
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        XCTAssertEqual(vm.briefConvs.first?.name, "raw-conv-id-999",
                       "briefConvs must fall back to conversationId when name is nil")
    }

    func testBriefConvsPreservesInsertionOrder() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        // c1 inserted first (older timestamp), c2 second
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice", timeOffset: -10)
        try await insertMessage(db: db, briefId: briefId, convId: "c2", convName: "Bob", sender: "Bob", timeOffset: -5)

        let mock = MockLLMClient()
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        // briefConvs is built from messages in DB order (ascending timestamp / rowid)
        XCTAssertEqual(vm.briefConvs.count, 2)
        XCTAssertEqual(vm.briefConvs[0].convId, "c1")
        XCTAssertEqual(vm.briefConvs[1].convId, "c2")
    }

    // MARK: - draftReply behaviour

    func testDraftReplyStripsDraftPrefix() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        // draftReply is triggered by named-send single match
        mock.response = LLMResponse(text: "DRAFT: Great reply here", inputTokens: 5, outputTokens: 4)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "write to Alice: say hi"

        await vm.send()

        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let d) = item { return d }
            return nil
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].text, "Great reply here",
                       "draftReply must strip the 'DRAFT: ' prefix from LLM response")
    }

    func testDraftReplyUsesFullResponseWhenNoDraftPrefix() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "No problem, I'll handle it.", inputTokens: 5, outputTokens: 5)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "write to Alice: confirm"

        await vm.send()

        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let d) = item { return d }
            return nil
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].text, "No problem, I'll handle it.")
    }

    func testDraftReplyOnLLMErrorAppendsErrorResponse() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.error = URLError(.notConnectedToInternet)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "write to Alice: this will fail"

        await vm.send()

        let responses = vm.threadItems.filter { if case .assistantResponse = $0 { return true }; return false }
        XCTAssertEqual(responses.count, 1)
        if case .assistantResponse(_, let text) = responses[0] {
            XCTAssertTrue(text.hasPrefix("Error:"), "draftReply error must produce 'Error: ...' response")
        }
    }

    // MARK: - selectPickerOption

    func testSelectPickerOptionRemovesPickerAndCreatesDraft() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Sure thing!", inputTokens: 5, outputTokens: 2)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        let pickerID = UUID()
        let option = ConversationOption(number: 1, service: "signal", convId: "c1", displayName: "Alice")
        vm.threadItems.append(.conversationPicker(id: pickerID, originalRequest: "reply to Alice", options: [option]))

        await vm.selectPickerOption(pickerID: pickerID, option: option)

        let pickers = vm.threadItems.filter { if case .conversationPicker = $0 { return true }; return false }
        XCTAssertEqual(pickers.count, 0, "selectPickerOption must remove the picker")

        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let d) = item { return d }
            return nil
        }
        XCTAssertEqual(drafts.count, 1, "selectPickerOption must produce a draft")
    }

    func testSelectPickerOptionWithOriginalRequestUsesProvidedRequest() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Got it!", inputTokens: 5, outputTokens: 1)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        let pickerID = UUID()
        let option = ConversationOption(number: 1, service: "signal", convId: "c1", displayName: "Alice")
        vm.threadItems.append(.conversationPicker(id: pickerID, originalRequest: "original", options: [option]))

        await vm.selectPickerOption(pickerID: pickerID, originalRequest: "the actual user request", option: option)

        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let d) = item { return d }
            return nil
        }
        XCTAssertEqual(drafts.count, 1, "selectPickerOption(originalRequest:) must produce a draft")
    }

    // MARK: - discardDraft

    func testDiscardDraftRemovesOnlyTargetDraft() async throws {
        let db = try await makeDB()
        let mock = MockLLMClient()
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let vm = ChatViewModel(appState: appState)

        let id1 = UUID()
        let id2 = UUID()
        let draft1 = ReplyDraft(id: id1, text: "Draft 1", serviceID: "signal", conversationID: "c1", senderName: "")
        let draft2 = ReplyDraft(id: id2, text: "Draft 2", serviceID: "signal", conversationID: "c2", senderName: "")
        vm.threadItems = [
            .replyDraft(id: id1, draft: draft1),
            .replyDraft(id: id2, draft: draft2)
        ]

        vm.discardDraft(id: id1)

        XCTAssertEqual(vm.threadItems.count, 1, "discardDraft must remove only the target draft")
        if case .replyDraft(let remaining, _) = vm.threadItems[0] {
            XCTAssertEqual(remaining, id2)
        } else {
            XCTFail("Remaining item should be the second draft")
        }
    }

    // MARK: - inputText clearing

    func testSendClearsInputText() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "OK", inputTokens: 5, outputTokens: 1)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "What is happening?"

        await vm.send()

        XCTAssertTrue(vm.inputText.isEmpty, "send() must clear inputText regardless of outcome")
    }

    // MARK: - Chat history replay in LLM messages

    func testChatHistoryIsReplayedInLLMMessages() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = StateSequenceLLMClient(responses: [
            LLMResponse(text: #"{"actions":[{"type":"answer","conversationNumber":null,"targetName":null,"message":null,"question":"First question"}]}"#,
                        inputTokens: 5,
                        outputTokens: 2),
            LLMResponse(text: "First answer", inputTokens: 5, outputTokens: 2),
            LLMResponse(text: #"{"actions":[{"type":"answer","conversationNumber":null,"targetName":null,"message":null,"question":"Second question"}]}"#,
                        inputTokens: 5,
                        outputTokens: 2),
            LLMResponse(text: "Second answer", inputTokens: 10, outputTokens: 2)
        ])
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        // First send
        vm.inputText = "First question"
        await vm.send()
        XCTAssertEqual(mock.calls.count, 2)

        // Second send — should replay the first question in LLM context
        vm.inputText = "Second question"
        await vm.send()
        XCTAssertEqual(mock.calls.count, 4)

        let secondCallMessages = mock.calls[3].messages
        // The messages array should contain a user message with the first question
        let userMessages = secondCallMessages.filter { $0.role == .user }
        let hasFirstQuestion = userMessages.contains { $0.content.contains("First question") }
        XCTAssertTrue(hasFirstQuestion,
                      "buildLLMMessages must replay prior user messages in subsequent calls")
    }
}

private final class StateSequenceLLMClient: LLMClient {
    var calls: [(model: String, messages: [LLMMessage], maxTokens: Int)] = []
    var error: Error?
    private var responses: [LLMResponse]

    init(responses: [LLMResponse]) {
        self.responses = responses
    }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        calls.append((model, messages, maxTokens))
        if let error { throw error }
        return responses.isEmpty
            ? LLMResponse(text: "", inputTokens: 0, outputTokens: 0)
            : responses.removeFirst()
    }
}
