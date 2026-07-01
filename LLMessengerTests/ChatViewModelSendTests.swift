// LLMessengerTests/ChatViewModelSendTests.swift
import XCTest
import GRDB
@testable import LLMessenger

// MARK: - Test-local adapter (SpyAdapter in ChatViewModelTests.swift is private)

internal final class SendTestSpyAdapter: MessengerAdapter {
    func listContacts() async -> [Contact] { [] }
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

private final class SendTestCloudLLMClient: LLMClient {
    var callCount = 0
    var isLocal: Bool { false }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        callCount += 1
        return LLMResponse(text: "DRAFT: ok", inputTokens: 1, outputTokens: 1)
    }
}

// MARK: - Helpers

@MainActor
final class ChatViewModelSendTests: XCTestCase {

    // MARK: Setup helpers

    private func makeDB() async throws -> AppDatabase {
        try AppDatabase(inMemory: true)
    }

    private func insertBrief(db: AppDatabase,
                             services: String = #"["signal"]"#,
                             openingSummary: String? = nil) async throws -> Int64 {
        try await db.dbQueue.write { d in
            var b = Brief(createdAt: Date(), status: "ready", services: services,
                          openingSummary: openingSummary, notificationText: "x", episodicSummary: nil)
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

    private func saveContext(db: AppDatabase,
                             service: String = "signal",
                             conversationId: String = "c1",
                             privacyOverride: String?) async throws {
        try await db.dbQueue.write { d in
            let ctx = ConversationContext(
                service: service,
                conversationId: conversationId,
                label: "",
                priorityHint: "auto",
                updatedAt: Date(),
                privacyOverride: privacyOverride
            )
            try ctx.save(d)
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

    func testAskForDetailsSubmitsContextualFollowUp() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Alice needs the address by noon.", inputTokens: 8, outputTokens: 7)
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)

        await vm.askForDetails(
            service: "signal",
            conversationID: "c1",
            displayName: "Alice",
            headline: "Alice asked for the address"
        )

        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertTrue(vm.threadItems.contains {
            if case .userMessage(_, let text) = $0 {
                return text == "Tell me more about Alice: Alice asked for the address"
            }
            return false
        })
        XCTAssertEqual(mock.calls[0].messages.last?.content,
                       "Tell me more about Alice: Alice asked for the address")
    }

    func testPrepareReplyPrefillsComposerAndRequestsFocus() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = MockLLMClient()
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        let previousFocusRequest = vm.inputFocusRequest

        vm.prepareReply(service: "signal", conversationID: "c1", displayName: "Alice")

        XCTAssertEqual(vm.inputText, "write to Alice: ")
        XCTAssertNotEqual(vm.inputFocusRequest, previousFocusRequest)
        XCTAssertEqual(mock.calls.count, 0, "Preparing a reply must not call the LLM until the user sends")
    }

    func testMentionTargetDraftRespectsNeverDraftPrivacy() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")
        try await saveContext(db: db, privacyOverride: "never_draft")

        let mock = MockLLMClient()
        let (vm, _) = try await makeVM(db: db, mock: mock, briefId: briefId)
        vm.setMentionTarget(.init(service: "signal", conversationId: "c1", displayName: "Alice", isGroup: false))
        vm.inputText = "yes works"

        await vm.send()

        XCTAssertEqual(mock.calls.count, 0)
        XCTAssertTrue(vm.threadItems.contains {
            if case .assistantResponse(_, let text) = $0 {
                return text.contains("Drafting is disabled")
            }
            return false
        })
    }

    func testMentionTargetDraftRespectsLocalOnlyWhenUsingCloudClient() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")
        try await saveContext(db: db, privacyOverride: "local_only")

        let cloud = SendTestCloudLLMClient()
        let appState = AppState(database: db, llmClient: cloud, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)
        vm.setMentionTarget(.init(service: "signal", conversationId: "c1", displayName: "Alice", isGroup: false))
        vm.inputText = "yes works"

        await vm.send()

        XCTAssertEqual(cloud.callCount, 0)
        XCTAssertTrue(vm.threadItems.contains {
            if case .assistantResponse(_, let text) = $0 {
                return text.contains("local-only")
            }
            return false
        })
    }

    func testNaturalLanguageReplyAndDetailsRunsBothActions() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db,
                                briefId: briefId,
                                convId: "asia-dm",
                                convName: "Asia",
                                sender: "Asia",
                                text: "Can you confirm?")
        try await insertMessage(db: db,
                                briefId: briefId,
                                convId: "mu11",
                                convName: "mu11 group",
                                sender: "Marta",
                                text: "Training moved to 19:00")

        let mock = SequenceLLMClient(responses: [
            LLMResponse(text: #"{"actions":[{"type":"draft_reply","conversationNumber":1,"targetName":"Asia","message":"ok","question":null},{"type":"answer","conversationNumber":2,"targetName":"mu11 group","message":null,"question":"give me more details about the chat in mu11 group"}]}"#,
                        inputTokens: 20,
                        outputTokens: 12),
            LLMResponse(text: "ok", inputTokens: 4, outputTokens: 1),
            LLMResponse(text: "The mu11 group is discussing the training time.", inputTokens: 12, outputTokens: 9)
        ])
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)

        vm.inputText = #"replay to Asia "ok" and give me more details about the chat in mu11 group"#

        await vm.send()

        XCTAssertEqual(mock.calls.count, 3)
        XCTAssertTrue(vm.threadItems.contains {
            if case .userMessage(_, let text) = $0 {
                return text == #"replay to Asia "ok" and give me more details about the chat in mu11 group"#
            }
            return false
        })

        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let draft) = item { return draft }
            return nil
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].text, "ok")
        XCTAssertEqual(drafts[0].conversationID, "asia-dm")

        let responses = vm.threadItems.compactMap { item -> String? in
            if case .assistantResponse(_, let text) = item { return text }
            return nil
        }
        XCTAssertEqual(responses.last, "The mu11 group is discussing the training time.")
        XCTAssertEqual(mock.calls[2].messages.last?.content,
                       "give me more details about the chat in mu11 group")
    }

    func testIntentRouterPromptIncludesRecentEpisodicContext() async throws {
        let db = try await makeDB()
        let currentBriefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: currentBriefId, convId: "asia-dm", convName: "Asia")
        try await db.dbQueue.write { d in
            var previous = Brief(createdAt: Date().addingTimeInterval(-3600),
                                 status: "ready",
                                 services: #"["signal"]"#,
                                 openingSummary: nil,
                                 notificationText: "older",
                                 episodicSummary: "Earlier Asia asked whether Thursday still works.")
            try previous.insert(d)
        }

        let mock = SequenceLLMClient(responses: [
            LLMResponse(text: #"{"actions":[{"type":"clarify","conversationNumber":null,"cardNumber":null,"draftNumber":null,"targetName":null,"message":null,"question":"Which thread do you want to focus on?","instruction":null}]}"#,
                        inputTokens: 8,
                        outputTokens: 6)
        ])
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: currentBriefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)
        vm.inputText = "what should I do?"

        await vm.send()

        XCTAssertEqual(mock.calls.count, 1)
        let routerPrompt = try XCTUnwrap(mock.calls[0].messages.first?.content)
        XCTAssertTrue(routerPrompt.contains("Recent context from prior sessions:"))
        XCTAssertTrue(routerPrompt.contains("Earlier Asia asked whether Thursday still works."))
    }

    func testUnknownRouterActionFallsBackWithoutDuplicatingUserMessage() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "c1", convName: "Alice")

        let mock = SequenceLLMClient(responses: [
            LLMResponse(text: #"{"actions":[{"type":"calendar","conversationNumber":null,"targetName":null,"message":null,"question":"What did Alice say?"}]}"#,
                        inputTokens: 8,
                        outputTokens: 6),
            LLMResponse(text: "Alice asked for the address.", inputTokens: 8, outputTokens: 6)
        ])
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)

        vm.inputText = "What did Alice say?"

        await vm.send()

        XCTAssertEqual(mock.calls.count, 2)
        let userMessages = vm.threadItems.compactMap { item -> String? in
            if case .userMessage(_, let text) = item { return text }
            return nil
        }
        XCTAssertEqual(userMessages, ["What did Alice say?"])
        let responses = vm.threadItems.compactMap { item -> String? in
            if case .assistantResponse(_, let text) = item { return text }
            return nil
        }
        XCTAssertEqual(responses.last, "Alice asked for the address.")
    }

    func testReviseDraftIntentUpdatesExistingDraft() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "asia-dm", convName: "Asia")

        let mock = SequenceLLMClient(responses: [
            LLMResponse(text: #"{"actions":[{"type":"revise_draft","conversationNumber":null,"cardNumber":null,"draftNumber":1,"targetName":null,"message":null,"question":null,"instruction":"make it shorter"}]}"#,
                        inputTokens: 8,
                        outputTokens: 6),
            LLMResponse(text: "ok", inputTokens: 8, outputTokens: 1)
        ])
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)
        let draftID = UUID()
        vm.threadItems.append(.replyDraft(id: draftID,
                                          draft: ReplyDraft(id: draftID,
                                                            text: "That sounds good to me.",
                                                            serviceID: "signal",
                                                            conversationID: "asia-dm",
                                                            senderName: "Asia")))
        vm.inputText = "make it shorter"

        await vm.send()

        XCTAssertEqual(mock.calls.count, 2)
        let drafts = vm.threadItems.compactMap { item -> ReplyDraft? in
            if case .replyDraft(_, let draft) = item { return draft }
            return nil
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].text, "ok")
        XCTAssertEqual(drafts[0].conversationID, "asia-dm")
    }

    func testDraftReplyIncludesRecentConversationContextAndPriorSummary() async throws {
        let db = try await makeDB()
        let currentBriefId = try await insertBrief(db: db)
        try await insertMessage(db: db,
                                briefId: currentBriefId,
                                convId: "asia-dm",
                                convName: "Asia",
                                sender: "Asia",
                                text: "Can you confirm for today?",
                                timeOffset: 0)
        try await db.dbQueue.write { d in
            var previous = Brief(createdAt: Date().addingTimeInterval(-3600),
                                 status: "ready",
                                 services: #"["signal"]"#,
                                 openingSummary: nil,
                                 notificationText: "older",
                                 episodicSummary: "Asia and I were discussing whether today's timing still stands.")
            try previous.insert(d)
            let previousBriefId = previous.id ?? 0
            var oldMessage = Message(briefId: previousBriefId,
                                     service: "signal",
                                     conversationId: "asia-dm",
                                     conversationName: "Asia",
                                     messageId: "asia-old-1",
                                     sender: "me",
                                     text: "Yesterday I said I'd confirm in the morning.",
                                     timestamp: Date().addingTimeInterval(-1800),
                                     isSent: true)
            try oldMessage.insert(d)
        }

        let mock = SequenceLLMClient(responses: [
            LLMResponse(text: #"{"actions":[{"type":"draft_reply","conversationNumber":1,"cardNumber":null,"draftNumber":null,"targetName":"Asia","message":"ok","question":null,"instruction":null}]}"#,
                        inputTokens: 10,
                        outputTokens: 8),
            LLMResponse(text: "ok", inputTokens: 6, outputTokens: 1)
        ])
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: currentBriefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)
        vm.inputText = #"reply to Asia "ok""#

        await vm.send()

        XCTAssertEqual(mock.calls.count, 2)
        let draftPrompt = try XCTUnwrap(mock.calls[1].messages.first?.content)
        XCTAssertTrue(draftPrompt.contains("Asia and I were discussing whether today's timing still stands."))

        let conversationContext = try XCTUnwrap(mock.calls[1].messages.dropFirst().first?.content)
        XCTAssertTrue(conversationContext.contains("Yesterday I said I'd confirm in the morning."))
        XCTAssertTrue(conversationContext.contains("Can you confirm for today?"))
    }

    func testSendDraftIntentRequiresConfirmationBeforeSending() async throws {
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db)
        try await insertMessage(db: db, briefId: briefId, convId: "asia-dm", convName: "Asia")

        let mock = SequenceLLMClient(responses: [
            LLMResponse(text: #"{"actions":[{"type":"send_draft_request","conversationNumber":null,"cardNumber":null,"draftNumber":1,"targetName":null,"message":null,"question":null,"instruction":null}]}"#,
                        inputTokens: 8,
                        outputTokens: 6)
        ])
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let spy = SendTestSpyAdapter(serviceID: "signal")
        appState.adapters["signal"] = spy
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)
        let draftID = UUID()
        vm.threadItems.append(.replyDraft(id: draftID,
                                          draft: ReplyDraft(id: draftID,
                                                            text: "ok",
                                                            serviceID: "signal",
                                                            conversationID: "asia-dm",
                                                            senderName: "Asia")))
        vm.inputText = "send it"

        await vm.send()

        XCTAssertEqual(spy.sentMessages.count, 0)
        let confirmations = vm.threadItems.compactMap { item -> (UUID, ReplyDraft)? in
            if case .sendConfirmation(let id, let draft) = item { return (id, draft) }
            return nil
        }
        XCTAssertEqual(confirmations.count, 1)
        XCTAssertEqual(confirmations[0].1.text, "ok")

        await vm.confirmSendDraft(id: confirmations[0].0)

        XCTAssertEqual(spy.sentMessages.count, 1)
        XCTAssertEqual(spy.sentMessages[0].conversationID, "asia-dm")
        XCTAssertEqual(spy.sentMessages[0].text, "ok")
    }

    func testShowSourcesForCardUsesSourceMessageIds() async throws {
        let summary = """
        {"cards":[{"id":"card-1","service":"signal","conversationId":"mu11","conversationTitle":"mu11 group","headline":"Training moved","priority":"high","counts":{"messages":1,"threads":1,"people":1},"summary":"Training moved to 19:00","callback":null,"actionItems":[],"quotes":[],"sourceMessageIds":["m-mu11-1"]}]}
        """
        let db = try await makeDB()
        let briefId = try await insertBrief(db: db, openingSummary: summary)
        try await insertMessage(db: db,
                                briefId: briefId,
                                convId: "mu11",
                                convName: "mu11 group",
                                sender: "Marta",
                                text: "Training moved to 19:00")
        try await db.dbQueue.write { d in
            if var message = try Message.fetchOne(d) {
                message.messageId = "m-mu11-1"
                try message.update(d)
            }
        }

        let mock = SequenceLLMClient(responses: [
            LLMResponse(text: #"{"actions":[{"type":"show_sources","conversationNumber":null,"cardNumber":1,"draftNumber":null,"targetName":null,"message":null,"question":null,"instruction":null}]}"#,
                        inputTokens: 8,
                        outputTokens: 6)
        ])
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)
        vm.inputText = "show sources for the first one"

        await vm.send()

        let sourcedResponses = vm.threadItems.compactMap { item -> [ThreadSource]? in
            if case .assistantResponseWithSources(_, _, let sources) = item { return sources }
            return nil
        }
        XCTAssertEqual(sourcedResponses.count, 1)
        XCTAssertEqual(sourcedResponses[0].map(\.text), ["Training moved to 19:00"])
    }

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

        // Intent routing uses one LLM call, then draftReply uses a second LLM call.
        XCTAssertEqual(mock.calls.count, 2)
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

        // Intent routing is attempted first, then the local fallback creates the picker.
        XCTAssertEqual(mock.calls.count, 1)
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

private final class SequenceLLMClient: LLMClient {
    var calls: [(model: String, messages: [LLMMessage], maxTokens: Int)] = []
    private var responses: [LLMResponse]

    init(responses: [LLMResponse]) {
        self.responses = responses
    }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        calls.append((model, messages, maxTokens))
        if responses.isEmpty {
            return LLMResponse(text: "", inputTokens: 0, outputTokens: 0)
        }
        return responses.removeFirst()
    }
}
