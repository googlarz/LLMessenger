// LLMessengerTests/GlossaryPromptTests.swift
import XCTest
import GRDB
@testable import LLMessenger

final class GlossaryPromptTests: XCTestCase {

    private func context(aliases: [String]) -> ConversationContext {
        var ctx = ConversationContext(
            service: "signal", conversationId: "c1", label: "Hoops",
            priorityHint: "auto", updatedAt: Date()
        )
        ctx.aliasesList = aliases
        return ctx
    }

    func testAliasesAppearAsGlossaryLine() {
        let prompt = PromptBuilder.build(
            mode: .summarizer, basePrompt: "BASE", services: ["signal"],
            episodicSummaries: [], now: Date(),
            conversationContexts: [context(aliases: ["The Hall = home venue", "Coach = official announcements"])]
        )
        XCTAssertTrue(prompt.contains("glossary: The Hall = home venue; Coach = official announcements"))
    }

    func testEmptyAliasesOmitGlossaryLine() {
        let prompt = PromptBuilder.build(
            mode: .summarizer, basePrompt: "BASE", services: ["signal"],
            episodicSummaries: [], now: Date(),
            conversationContexts: [context(aliases: [])]
        )
        XCTAssertFalse(prompt.contains("glossary:"))
    }

    func testAliasesColumnRoundTripsThroughV20() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = BriefRepository(database: db)
        var ctx = ConversationContext(
            service: "signal", conversationId: "c1", label: "Hoops",
            priorityHint: "auto", updatedAt: Date()
        )
        ctx.aliasesList = ["The Hall = home venue"]
        try repo.upsertConversationContext(ctx)
        let loaded = try repo.fetchConversationContext(service: "signal", conversationId: "c1")
        XCTAssertEqual(loaded?.aliasesList, ["The Hall = home venue"])
    }
}
