// LLMessengerTests/PromptRegressionTests.swift
// AI-specific regression tests. The entire system's quality depends on what is sent to the LLM.
// A silent change to PromptBuilder or BriefEngine's message construction can break every brief
// in production while all other tests stay green. These tests lock down the structural contract.
//
// Two layers:
//  1. PromptBuilder unit tests — call PromptBuilder.build() directly, no engine overhead.
//  2. BriefEngine integration tests — capture what BriefEngine actually sends, including
//     the user content (conversation blocks) that PromptBuilder cannot test alone.
import XCTest
import GRDB
@testable import LLMessenger

// MARK: - CapturingMockLLMClient
//
// Records the (systemPrompt, userContent) sent on each call and returns valid JSON so
// BriefEngine proceeds. Used only for integration-level prompt inspection.

final class CapturingMockLLMClient: LLMClient {
    struct CapturedCall {
        let systemPrompt: String
        let userContent: String
    }
    private(set) var capturedCalls: [CapturedCall] = []
    var specs: [String: DynamicMockLLMClient.Spec] = [:]

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        let sys  = messages.first(where: { $0.role == .system })?.content ?? ""
        let user = messages.first(where: { $0.role == .user   })?.content ?? ""
        capturedCalls.append(CapturedCall(systemPrompt: sys, userContent: user))

        if sys.contains("2-3 sentences") {
            return LLMResponse(text: "Episodic summary.", inputTokens: 5, outputTokens: 5)
        }
        let connectedLine = sys.split(separator: "\n")
            .first { $0.hasPrefix("Connected services:") }
            .map(String.init) ?? ""
        let service = ["signal", "telegram", "imessage"].first { connectedLine.contains($0) } ?? "unknown"
        guard let spec = specs[service] else {
            throw NSError(domain: "CapturingMock", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No spec for '\(service)'"])
        }
        let ids = spec.messageIds.map { "\"\($0)\"" }.joined(separator: ", ")
        let cardId = "\(service)-\(spec.convId)-\(spec.messageIds.first ?? UUID().uuidString)"
        let json = """
        {"cards":[{"id":"\(cardId)","service":"\(service)",
        "conversationId":"\(spec.convId)","headline":"H","priority":"medium",
        "summary":"S","counts":{"messages":\(spec.messageIds.count),"threads":1,"people":1},
        "sourceMessageIds":[\(ids)]}]}
        """
        return LLMResponse(text: json, inputTokens: 10, outputTokens: 20)
    }
}

// MARK: - Layer 1: PromptBuilder unit tests (no engine, no DB)

final class PromptBuilderStructureTests: XCTestCase {

    private let now = Date()

    // MARK: Base prompt

    func testBasePromptPrefixesSystemPrompt() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "MY_BASE",
                                         services: ["signal"], episodicSummaries: [], now: now)
        XCTAssertTrue(prompt.hasPrefix("MY_BASE"),
                      "System prompt must start with the configured base prompt")
    }

    // MARK: Date

    func testCurrentDateAppearsInSystemPrompt() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["signal"], episodicSummaries: [], now: now)
        XCTAssertTrue(prompt.contains("Current date:"),
                      "System prompt must include 'Current date:' for temporal reasoning")
    }

    // MARK: Service listing

    func testSingleServiceAppearsInConnectedServicesLine() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["telegram"], episodicSummaries: [], now: now)
        XCTAssertTrue(prompt.contains("Connected services: telegram"),
                      "System prompt must list the service in 'Connected services:' line")
    }

    func testMultipleServicesAllAppearInConnectedServicesLine() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["signal", "telegram"], episodicSummaries: [], now: now)
        XCTAssertTrue(prompt.contains("signal"), "signal must appear in Connected services")
        XCTAssertTrue(prompt.contains("telegram"), "telegram must appear in Connected services")
    }

    func testNoServicesOmitsConnectedServicesLine() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: [], episodicSummaries: [], now: now)
        XCTAssertFalse(prompt.contains("Connected services:"),
                       "Connected services line must be omitted when services array is empty")
    }

    // MARK: JSON schema contract
    // These field names are validated by BriefEngine. If they disappear from the prompt
    // the LLM won't know to produce them → silent validation failures in production.

    func testSummarizerPromptInstructsLLMToProduceSourceMessageIds() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["signal"], episodicSummaries: [], now: now)
        XCTAssertTrue(prompt.contains("sourceMessageIds"),
                      "Prompt must instruct LLM to produce sourceMessageIds — BriefEngine validates these")
    }

    func testSummarizerPromptInstructsLLMToProduceConversationId() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["signal"], episodicSummaries: [], now: now)
        XCTAssertTrue(prompt.contains("conversationId"),
                      "Prompt must instruct LLM to produce conversationId — used to link cards to threads")
    }

    func testSummarizerPromptInstructsLLMToProduceService() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["signal"], episodicSummaries: [], now: now)
        // Verify "service" appears as a JSON field instruction, not just as part of "Connected services:"
        XCTAssertTrue(prompt.contains("\"service\""),
                      "Prompt must instruct LLM to produce \\\"service\\\" field in JSON output")
    }

    func testSummarizerPromptInstructsLLMToOutputOnlyJSON() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["signal"], episodicSummaries: [], now: now)
        XCTAssertTrue(prompt.lowercased().contains("only valid json") ||
                      prompt.contains("ONLY valid JSON") ||
                      prompt.contains("Output ONLY"),
                      "Prompt must forbid prose/markdown — LLM must return raw JSON only")
    }

    // MARK: Conversation block header format contract
    // BriefEngine builds blocks with "=== [service] convId | title ===" and instructs the LLM
    // to copy the service tag verbatim. If this format changes, card.service validation breaks.

    func testSummarizerPromptContainsConversationBlockHeaderFormatExample() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["signal"], episodicSummaries: [], now: now)
        XCTAssertTrue(prompt.contains("=== ["),
                      "Prompt must document the '=== [service] convId | title ===' header format")
    }

    // MARK: Episodic summaries

    func testEpisodicSummariesIncludedWhenProvided() {
        let summaries = [(summary: "Alice mentioned the Q3 launch.", createdAt: Date().addingTimeInterval(-3600))]
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["signal"], episodicSummaries: summaries, now: now)
        XCTAssertTrue(prompt.contains("Alice mentioned the Q3 launch."),
                      "Episodic summaries must be injected into the system prompt")
        XCTAssertTrue(prompt.contains("Recent context from prior sessions:"),
                      "Episodic summaries must be labelled clearly")
    }

    func testEpisodicSummariesOmittedWhenEmpty() {
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["signal"], episodicSummaries: [], now: now)
        XCTAssertFalse(prompt.contains("Recent context from prior sessions:"),
                       "Episodic context section must be absent when there are no summaries")
    }

    func testMultipleEpisodicSummariesAllIncluded() {
        let summaries = [
            (summary: "First session note.", createdAt: Date().addingTimeInterval(-7200)),
            (summary: "Second session note.", createdAt: Date().addingTimeInterval(-3600))
        ]
        let prompt = PromptBuilder.build(mode: .summarizer, basePrompt: "B",
                                         services: ["signal"], episodicSummaries: summaries, now: now)
        XCTAssertTrue(prompt.contains("First session note."), "First episodic summary must appear")
        XCTAssertTrue(prompt.contains("Second session note."), "Second episodic summary must appear")
    }
}

// MARK: - Layer 2: BriefEngine integration — what actually gets sent

@MainActor
final class PromptIntegrationTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    // MARK: Service isolation regression
    // Guards the bug found during test development: PromptBuilder's suffix embeds
    // "=== [signal] abc123 | Alice ===" as a format example, so every service's system prompt
    // contains the word "signal". Service detection must use the "Connected services:" line only.

    func testTelegramBriefingCallConnectedServicesLineContainsOnlyTelegram() async throws {
        let db = try makeDB()
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "telegram", conversationId: "t1",
                            conversationName: "Bob", messageId: "tg-m1",
                            sender: "Bob", text: "Hey", timestamp: Date(), isSent: false)
            try m.insert(d)
        }
        let mock = CapturingMockLLMClient()
        mock.specs["telegram"] = .init(convId: "t1", messageIds: ["tg-m1"])
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try await engine.processNewMessages()

        let sys = try XCTUnwrap(mock.capturedCalls.first?.systemPrompt)
        let connectedLine = sys.split(separator: "\n")
            .first { $0.hasPrefix("Connected services:") }
            .map(String.init) ?? ""
        XCTAssertEqual(connectedLine, "Connected services: telegram",
                       "Telegram call must only list telegram in Connected services — not signal or imessage")
    }

    // MARK: Conversation block format

    func testUserContentConversationBlockHeaderFormat() async throws {
        let db = try makeDB()
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "alice-conv",
                            conversationName: "Alice Johnson",
                            messageId: "m1", sender: "Alice", text: "Hello",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }
        let mock = CapturingMockLLMClient()
        mock.specs["signal"] = .init(convId: "alice-conv", messageIds: ["m1"])
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try await engine.processNewMessages()

        let user = try XCTUnwrap(mock.capturedCalls.first?.userContent)
        XCTAssertTrue(user.contains("=== [signal] alice-conv |"),
                      "User content must have '=== [signal] alice-conv |' header — LLM copies service tag verbatim")
        XCTAssertTrue(user.contains("Alice Johnson"),
                      "User content must include the conversation display name")
    }

    func testUserContentContainsMessageText() async throws {
        let db = try makeDB()
        try await db.dbQueue.write { d in
            var m = Message(briefId: nil, service: "signal", conversationId: "c1",
                            conversationName: "Alice",
                            messageId: "m1", sender: "Alice",
                            text: "Meeting moved to Thursday at 3pm",
                            timestamp: Date(), isSent: false)
            try m.insert(d)
        }
        let mock = CapturingMockLLMClient()
        mock.specs["signal"] = .init(convId: "c1", messageIds: ["m1"])
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try await engine.processNewMessages()

        let user = try XCTUnwrap(mock.capturedCalls.first?.userContent)
        XCTAssertTrue(user.contains("Meeting moved to Thursday at 3pm"),
                      "User content must contain the actual message text for the LLM to summarize")
    }

    func testTwoConversationsProduceTwoBlockHeaders() async throws {
        let db = try makeDB()
        try await db.dbQueue.write { d in
            var m1 = Message(briefId: nil, service: "signal", conversationId: "conv-alice",
                             conversationName: "Alice", messageId: "m1", sender: "Alice",
                             text: "Hi", timestamp: Date().addingTimeInterval(-5), isSent: false)
            try m1.insert(d)
            var m2 = Message(briefId: nil, service: "signal", conversationId: "conv-bob",
                             conversationName: "Bob", messageId: "m2", sender: "Bob",
                             text: "Hey", timestamp: Date(), isSent: false)
            try m2.insert(d)
        }
        let mock = CapturingMockLLMClient()
        // Return JSON for one conv so engine succeeds; we only care about userContent
        mock.specs["signal"] = .init(convId: "conv-alice", messageIds: ["m1"])
        let engine = BriefEngine(database: db, client: mock, model: "m", basePrompt: "B")
        _ = try? await engine.processNewMessages()

        let user = try XCTUnwrap(mock.capturedCalls.first?.userContent)
        XCTAssertTrue(user.contains("=== [signal] conv-alice |"),
                      "Alice's conversation block must be present in user content")
        XCTAssertTrue(user.contains("=== [signal] conv-bob |"),
                      "Bob's conversation block must be present — all conversations go in one prompt")
    }
}
