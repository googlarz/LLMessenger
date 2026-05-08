// LLMessengerTests/ChatViewModelSendTests.swift
import XCTest
@testable import LLMessenger

// MARK: - Test-local adapter (SpyAdapter in ChatViewModelTests.swift is private)

internal final class SendTestSpyAdapter: MessengerAdapter {
    let serviceID: String
    var healthStatus: AdapterHealthResult.Status = .ok
    var sentMessages: [(conversationID: String, text: String)] = []

    init(serviceID: String) { self.serviceID = serviceID }

    func start() async throws {}
    func stop() {}
    func fetch(config: FetchConfig) async throws -> AdapterFetchResult { AdapterFetchResult(conversations: []) }
    func send(conversationID: String, text: String) async throws {
        sentMessages.append((conversationID, text))
    }
    func healthCheck() async -> AdapterHealthResult {
        AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil)
    }
}

// MARK: - Helpers

@MainActor
final class ChatViewModelSendTests: XCTestCase {

    // MARK: Setup helpers

    private func makeDB() async throws -> AppDatabase {
        try AppDatabase(inMemory: true)
    }

    private func insertBrief(db: AppDatabase, services: String = #"["signal"]"#) async throws -> Int64 {
        var briefId: Int64 = 0
        try await db.dbQueue.write { d in
            var b = Brief(createdAt: Date(), status: "ready", services: services,
                          openingSummary: nil, notificationText: "x", episodicSummary: nil)
            try b.insert(d)
            briefId = b.id!
        }
        return briefId
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
                        mock: MockLLMClient,
                        briefId: Int64) async throws -> (ChatViewModel, Brief) {
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)
        return (vm, brief)
    }

    // MARK: - Guard conditions

    func testSendDoesNothingWithEmptyInput() async throws {
        let db = try await makeDB()
        let mock = MockLLMClient()
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let vm = ChatViewModel(appState: appState)
        vm.inputText = "   "

        await vm.send()

        XCTAssertEqual(mock.calls.count, 0)
        XCTAssertTrue(vm.threadItems.isEmpty)
    }

    func testSendDoesNothingWithoutLoadedBrief() async throws {
        let db = try await makeDB()
        let mock = MockLLMClient()
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let vm = ChatViewModel(appState: appState)
        vm.inputText = "hello"

        await vm.send()

        XCTAssertEqual(mock.calls.count, 0)
        XCTAssertTrue(vm.threadItems.isEmpty)
    }

    // MARK: - Path 3: LLM response variants

    func testLLMResponsePlainTextAppendsAssistantResponse() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Alice said hello.", inputTokens: 5, outputTokens: 3)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "What did Alice say?"

        await vm.send()

        let responses = vm.threadItems.filter { if case .assistantResponse = $0 { return true }; return false }
        XCTAssertEqual(responses.count, 1)
        if case .assistantResponse(_, let text) = responses[0] {
            XCTAssertEqual(text, "Alice said hello.")
        } else {
            XCTFail("Expected assistantResponse")
        }
    }

    func testLLMResponseCHOOSEAppendsPicker() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice", timeOffset: -2)
        try await insertMessage(db: db, briefId: briefId, convId: "c2", convName: "Bob", sender: "Bob", timeOffset: -1)

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "CHOOSE", inputTokens: 5, outputTokens: 1)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "Reply to someone"

        await vm.send()

        let pickers = vm.threadItems.filter { if case .conversationPicker = $0 { return true }; return false }
        XCTAssertEqual(pickers.count, 1)
        if case .conversationPicker(_, let req, let opts) = pickers[0] {
            XCTAssertEqual(req, "Reply to someone")
            XCTAssertEqual(opts.count, 2)
        } else {
            XCTFail("Expected conversationPicker")
        }
    }

    func testLLMResponseDRAFTColonNCreatesReplyDraftForNthConv() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        // Insert c1 first, c2 second — order in briefConvs follows message order
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice", timeOffset: -2)
        try await insertMessage(db: db, briefId: briefId, convId: "c2", convName: "Bob", sender: "Bob", timeOffset: -1)

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "DRAFT:2: Hello Bob!", inputTokens: 5, outputTokens: 4)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "Draft a reply to Bob"

        await vm.send()

        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let d) = item { return d }
            return nil
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].text, "Hello Bob!")
        XCTAssertEqual(drafts[0].conversationID, "c2")
    }

    func testLLMResponseDRAFTColonNoNumberUsesFirstConv() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "DRAFT: Hi there!", inputTokens: 5, outputTokens: 3)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "Draft a quick hi"

        await vm.send()

        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let d) = item { return d }
            return nil
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].text, "Hi there!")
        XCTAssertEqual(drafts[0].conversationID, "c1")
    }

    func testLLMErrorAppendsAssistantResponseWithErrorPrefix() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.error = URLError(.notConnectedToInternet)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "What happened?"

        await vm.send()

        let responses = vm.threadItems.filter { if case .assistantResponse = $0 { return true }; return false }
        XCTAssertEqual(responses.count, 1)
        if case .assistantResponse(_, let text) = responses[0] {
            XCTAssertTrue(text.hasPrefix("Error:"), "Expected error prefix, got: \(text)")
        } else {
            XCTFail("Expected assistantResponse")
        }
    }

    // MARK: - Path 2: Named-send shortcut

    func testNamedSendSingleMatchCreatesDraftDirectly() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Hello!", inputTokens: 5, outputTokens: 2)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "write to Alice: hello there"

        await vm.send()

        // Named-send bypasses the chat LLM, goes directly to draftReply (which calls LLM once)
        XCTAssertEqual(mock.calls.count, 1)
        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let d) = item { return d }
            return nil
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].conversationID, "c1")
    }

    func testNamedSendMultipleMatchesCreatesPicker() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice Work", timeOffset: -2)
        try await insertMessage(db: db, briefId: briefId, convId: "c2", convName: "Alice Personal", sender: "Alice2", timeOffset: -1)

        let mock = MockLLMClient()
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "write to Alice: which one?"

        await vm.send()

        // Should NOT call LLM — returns early with picker
        XCTAssertEqual(mock.calls.count, 0)
        let pickers = vm.threadItems.filter { if case .conversationPicker = $0 { return true }; return false }
        XCTAssertEqual(pickers.count, 1)
        if case .conversationPicker(_, _, let opts) = pickers[0] {
            XCTAssertEqual(opts.count, 2)
        } else {
            XCTFail("Expected conversationPicker")
        }
    }

    func testNamedSendZeroMatchesFallsThroughToLLM() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "I couldn't find that person.", inputTokens: 5, outputTokens: 5)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "write to UnknownPerson123: hi there"

        await vm.send()

        // Falls through to LLM
        XCTAssertEqual(mock.calls.count, 1)
    }

    func testNamedSendVariantSend() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Bob", sender: "Bob")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Hi!", inputTokens: 5, outputTokens: 1)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "send to Bob: hey there"

        await vm.send()

        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let d) = item { return d }
            return nil
        }
        XCTAssertEqual(drafts.count, 1, "send to X: ... should trigger draft")
    }

    func testNamedSendVariantReply() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Charlie", sender: "Charlie")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Sure!", inputTokens: 5, outputTokens: 1)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.inputText = "reply to Charlie: sounds good"

        await vm.send()

        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let d) = item { return d }
            return nil
        }
        XCTAssertEqual(drafts.count, 1, "reply to X: ... should trigger draft")
    }

    // MARK: - Path 1: Picker resolution

    func testPickerResolutionByNumberCreatesDraft() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice", timeOffset: -2)
        try await insertMessage(db: db, briefId: briefId, convId: "c2", convName: "Bob", sender: "Bob", timeOffset: -1)

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Hello!", inputTokens: 5, outputTokens: 2)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        // Inject a picker as if CHOOSE was previously returned
        let pickerID = UUID()
        let options = [
            ConversationOption(number: 1, service: "signal", convId: "c1", displayName: "Alice"),
            ConversationOption(number: 2, service: "signal", convId: "c2", displayName: "Bob")
        ]
        vm.threadItems.append(.conversationPicker(id: pickerID, originalRequest: "reply to someone", options: options))
        vm.inputText = "1"

        await vm.send()

        // Picker must be removed
        let pickerCount = vm.threadItems.filter { if case .conversationPicker = $0 { return true }; return false }.count
        XCTAssertEqual(pickerCount, 0, "Picker should be removed after resolution")

        // Draft for option 1 (c1) should appear
        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let d) = item { return d }
            return nil
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].conversationID, "c1")
    }

    func testNonNumericInputWithActivePickerGoesToLLM() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Sure!", inputTokens: 5, outputTokens: 1)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        let options = [ConversationOption(number: 1, service: "signal", convId: "c1", displayName: "Alice")]
        vm.threadItems.append(.conversationPicker(id: UUID(), originalRequest: "reply", options: options))
        vm.inputText = "nevermind"

        await vm.send()

        // Non-numeric input → falls through to LLM
        XCTAssertEqual(mock.calls.count, 1)
        // Picker still present
        let pickers = vm.threadItems.filter { if case .conversationPicker = $0 { return true }; return false }
        XCTAssertEqual(pickers.count, 1, "Picker should remain when input is not numeric")
    }
}
