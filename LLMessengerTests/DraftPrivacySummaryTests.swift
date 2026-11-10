// LLMessengerTests/DraftPrivacySummaryTests.swift
//
// Episodic summaries are distilled from whole digests, so a summary made while a
// local model was in use can hold text from Local-only conversations. Prompts for a
// cloud client (Draft with AI, the Ask panel and its draft revision) must leave out
// every summary whose sources include a Local-only chat or are unknown, and drafting
// must fail closed when the privacy setting cannot be read.

import XCTest
import GRDB
@testable import LLMessenger

@MainActor
final class DraftPrivacySummaryTests: XCTestCase {

    private func makeState(llm: LLMClient) throws -> AppState {
        let db = try AppDatabase(inMemory: true)
        let defaults = UserDefaults(suiteName: "DraftPrivacySummaryTests-\(UUID().uuidString)")!
        return AppState(database: db, llmClient: llm, llmModel: "test", basePrompt: "", defaults: defaults)
    }

    @discardableResult
    private func seedBrief(_ state: AppState, summary: String, age: TimeInterval,
                           sources: [String]?) throws -> Int64 {
        try state.database.dbQueue.write { d in
            var b = Brief(createdAt: Date().addingTimeInterval(-age), status: "ready", services: "[\"signal\"]",
                          openingSummary: nil, notificationText: "n", episodicSummary: summary)
            try b.insert(d)
            let id = try XCTUnwrap(b.id)
            if let sources {
                let keys = Set(sources.map { BriefConversationKey(service: "signal", conversationID: $0) })
                try BriefRepository.insertBriefProvenance(BriefProvenance(conversations: keys), briefID: id, db: d)
            }
            return id
        }
    }

    private func setPrivacy(_ state: AppState, _ conv: String, _ value: String?) throws {
        var ctx = ConversationContext(service: "signal", conversationId: conv, label: "",
                                      priorityHint: "auto", updatedAt: Date())
        ctx.privacyOverride = value
        try state.repository.upsertConversationContext(ctx)
    }

    private func seedWorld(_ state: AppState) throws {
        try setPrivacy(state, "secret", "local_only")
        try setPrivacy(state, "never", "never_draft")
        try seedBrief(state, summary: "SUMMARY-LOCALONLY-CHAT", age: 10, sources: ["secret", "c2"])
        try seedBrief(state, summary: "SUMMARY-NEVERDRAFT-CHAT", age: 20, sources: ["never"])
        try seedBrief(state, summary: "SUMMARY-ORDINARY", age: 30, sources: ["c2"])
        try seedBrief(state, summary: "SUMMARY-UNKNOWN-SOURCES", age: 40, sources: nil)
    }

    private func allText(_ calls: [(model: String, messages: [LLMMessage], maxTokens: Int)]) -> String {
        calls.flatMap(\.messages).map(\.content).joined(separator: "\n---\n")
    }

    // MARK: Draft with AI

    func testCloudDraftPromptHasNoLocalOnlyDerivedOrUnknownSummaries() async throws {
        let cloud = MockLLMClient()
        cloud.response = LLMResponse(text: "ok", inputTokens: 1, outputTokens: 1)
        let state = try makeState(llm: cloud)
        try seedWorld(state)
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let request = try XCTUnwrap(state.replyComposer)

        _ = try await ReplyDrafter(appState: state).draft(request: request, currentText: "")

        let prompt = allText(cloud.calls)
        XCTAssertEqual(cloud.calls.count, 1)
        XCTAssertTrue(prompt.contains("SUMMARY-ORDINARY"), "ordinary summaries still help")
        XCTAssertFalse(prompt.contains("SUMMARY-LOCALONLY-CHAT"))
        XCTAssertFalse(prompt.contains("SUMMARY-NEVERDRAFT-CHAT"))
        XCTAssertFalse(prompt.contains("SUMMARY-UNKNOWN-SOURCES"))
    }

    func testLocalClientKeepsSummariesButNotNeverDraftOnes() async throws {
        let local = LocalMockLLMClient()
        local.response = LLMResponse(text: "ok", inputTokens: 1, outputTokens: 1)
        let state = try makeState(llm: local)
        try seedWorld(state)
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let request = try XCTUnwrap(state.replyComposer)

        _ = try await ReplyDrafter(appState: state).draft(request: request, currentText: "")

        let prompt = allText(local.calls)
        XCTAssertTrue(prompt.contains("SUMMARY-LOCALONLY-CHAT"), "Local-only text stays on a local model")
        XCTAssertTrue(prompt.contains("SUMMARY-ORDINARY"))
        XCTAssertTrue(prompt.contains("SUMMARY-UNKNOWN-SOURCES"))
        XCTAssertFalse(prompt.contains("SUMMARY-NEVERDRAFT-CHAT"), "never-draft chats are excluded for every client")
    }

    func testUnreadablePrivacyMeansNoDraftAndNoLLMCall() async throws {
        let cloud = MockLLMClient()
        let state = try makeState(llm: cloud)
        try await state.database.dbQueue.write { try $0.execute(sql: "DROP TABLE conversationContexts") }
        state.openReplyComposer(service: "signal", conversationId: "c1", conversationName: "Alice")
        let request = try XCTUnwrap(state.replyComposer)

        XCTAssertNotNil(ReplyDrafter(appState: state).blockedReason(service: "signal", conversationId: "c1"))
        do {
            _ = try await ReplyDrafter(appState: state).draft(request: request, currentText: "")
            XCTFail("must not draft")
        } catch {}
        XCTAssertEqual(cloud.calls.count, 0)
    }

    // MARK: Ask panel

    func testAskPanelPromptsHaveNoLocalOnlyDerivedSummariesForACloudClient() async throws {
        let cloud = MockLLMClient()
        cloud.response = LLMResponse(text: "Nothing new.", inputTokens: 1, outputTokens: 1)
        let state = try makeState(llm: cloud)
        try seedWorld(state)
        let briefID = try seedBrief(state, summary: "SUMMARY-CURRENT-BRIEF-UNKNOWN", age: 0, sources: nil)
        let brief = try XCTUnwrap(state.repository.fetchBrief(id: briefID))
        let chat = ChatViewModel(appState: state)
        try await chat.loadBrief(brief)

        chat.inputText = "What did Alice say last?"
        await chat.send()

        XCTAssertFalse(cloud.calls.isEmpty)
        let prompt = allText(cloud.calls)
        XCTAssertFalse(prompt.contains("SUMMARY-LOCALONLY-CHAT"))
        XCTAssertFalse(prompt.contains("SUMMARY-NEVERDRAFT-CHAT"))
        XCTAssertFalse(prompt.contains("SUMMARY-UNKNOWN-SOURCES"))
        XCTAssertFalse(prompt.contains("SUMMARY-CURRENT-BRIEF-UNKNOWN"))
        XCTAssertTrue(prompt.contains("SUMMARY-ORDINARY"))
    }

    func testReviseDraftPromptHasNoLocalOnlyDerivedSummariesForACloudClient() async throws {
        let cloud = MockLLMClient()
        cloud.response = LLMResponse(text: "Revised", inputTokens: 1, outputTokens: 1)
        let state = try makeState(llm: cloud)
        try seedWorld(state)
        let briefID = try seedBrief(state, summary: "SUMMARY-CURRENT-BRIEF-UNKNOWN", age: 0, sources: nil)
        let brief = try XCTUnwrap(state.repository.fetchBrief(id: briefID))
        let chat = ChatViewModel(appState: state)
        try await chat.loadBrief(brief)
        let draft = ReplyDraft(id: UUID(), text: "see you at 6", serviceID: "signal",
                               conversationID: "c1", senderName: "Alice")
        chat.threadItems = [.replyDraft(id: draft.id, draft: draft)]

        chat.inputText = "make it shorter"
        await chat.send()

        XCTAssertFalse(cloud.calls.isEmpty)
        let prompt = allText(cloud.calls)
        XCTAssertFalse(prompt.contains("SUMMARY-LOCALONLY-CHAT"))
        XCTAssertFalse(prompt.contains("SUMMARY-UNKNOWN-SOURCES"))
    }

    func testQuickRepliesMakeNoLLMCallWhenPrivacyCannotBeRead() async throws {
        let cloud = MockLLMClient()
        let state = try makeState(llm: cloud)
        let briefID = try seedBrief(state, summary: "s", age: 0, sources: ["c1"])
        let brief = try XCTUnwrap(state.repository.fetchBrief(id: briefID))
        let chat = ChatViewModel(appState: state)
        try await chat.loadBrief(brief)
        try await state.database.dbQueue.write { try $0.execute(sql: "DROP TABLE conversationContexts") }

        await chat.generateQuickReplies(cardID: "card", service: "signal", convId: "c1", convName: "Alice")

        XCTAssertEqual(cloud.calls.count, 0)
        XCTAssertTrue(chat.quickRepliesFailed.contains("card"))
    }
}
