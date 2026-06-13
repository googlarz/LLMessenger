// LLMessengerTests/PromptBuilderContextTests.swift
import XCTest
@testable import LLMessenger

final class PromptBuilderContextTests: XCTestCase {

    private func context(
        conversationId: String = "c1",
        label: String = "",
        relationship: String? = nil,
        important: [String] = [],
        noise: [String] = [],
        note: String? = nil
    ) -> ConversationContext {
        var ctx = ConversationContext(
            service: "signal", conversationId: conversationId, label: label,
            priorityHint: "auto", updatedAt: Date(),
            relationship: relationship, contextNote: note
        )
        ctx.importantTopicsList = important
        ctx.noiseTopicsList = noise
        return ctx
    }

    func testContextsWithFieldsAppearInPrompt() {
        let prompt = PromptBuilder.build(
            mode: .summarizer, basePrompt: "BASE", services: ["signal"],
            episodicSummaries: [], now: Date(),
            conversationContexts: [
                context(label: "Hoops", relationship: "son's team",
                        important: ["games"], noise: ["banter"], note: "flag coach")
            ]
        )
        XCTAssertTrue(prompt.contains("Conversation-specific context (honor these):"))
        XCTAssertTrue(prompt.contains("[Hoops]"))
        XCTAssertTrue(prompt.contains("relationship=son's team"))
        XCTAssertTrue(prompt.contains("important: games"))
        XCTAssertTrue(prompt.contains("ignore: banter"))
        XCTAssertTrue(prompt.contains("note: flag coach"))
    }

    func testEmptyContextsOmitted() {
        let prompt = PromptBuilder.build(
            mode: .summarizer, basePrompt: "BASE", services: ["signal"],
            episodicSummaries: [], now: Date(),
            conversationContexts: [context()]  // no non-empty v2 fields
        )
        XCTAssertFalse(prompt.contains("Conversation-specific context"))
    }

    func testNoContextsParamOmitsSection() {
        let prompt = PromptBuilder.build(
            mode: .summarizer, basePrompt: "BASE", services: ["signal"],
            episodicSummaries: [], now: Date()
        )
        XCTAssertFalse(prompt.contains("Conversation-specific context"))
    }
}
