// LLMessengerTests/PromptBuilderTests.swift
import XCTest
@testable import LLMessenger

final class PromptBuilderTests: XCTestCase {

    func testDefaultBasePromptContainsCoreInstructions() {
        let prompt = PromptBuilder.defaultBasePrompt
        XCTAssertTrue(prompt.contains("LLMessenger"))
        XCTAssertTrue(prompt.contains("Never send anything without the user's explicit confirmation"))
    }

    func testBuildSummarizerPromptInjectsContext() {
        let prompt = PromptBuilder.build(
            mode: .summarizer,
            basePrompt: "BASE",
            services: ["telegram", "signal"],
            episodicSummaries: [
                (summary: "Yesterday: Marta asked about deploy.", createdAt: Date()),
                (summary: "Today: João confirmed staging fix.", createdAt: Date())
            ],
            now: Date(timeIntervalSince1970: 1_746_465_600)
        )
        XCTAssertTrue(prompt.contains("BASE"))
        XCTAssertTrue(prompt.contains("telegram"))
        XCTAssertTrue(prompt.contains("signal"))
        XCTAssertTrue(prompt.contains("Marta asked about deploy"))
        XCTAssertTrue(prompt.contains("Produce a JSON brief"))
        XCTAssertTrue(prompt.contains("sourceMessageIds"))
        // Updated assertion: matches the new explicit extraction rule wording
        XCTAssertTrue(prompt.contains("[id="))
        XCTAssertTrue(prompt.contains("conversationId"))
    }

    func testBuildCompressorPromptHasCompressionSuffix() {
        let prompt = PromptBuilder.build(
            mode: .compressor,
            basePrompt: "BASE",
            services: [],
            episodicSummaries: [],
            now: Date()
        )
        XCTAssertTrue(prompt.contains("2-3 sentences"))
    }

    func testBuildConversationalistPromptHasChatSuffix() {
        let prompt = PromptBuilder.build(
            mode: .conversationalist,
            basePrompt: "BASE",
            services: [],
            episodicSummaries: [],
            now: Date()
        )
        XCTAssertTrue(prompt.contains("Answer the user"))
    }

    func testBuildReplyDrafterPromptHasDraftSuffix() {
        let prompt = PromptBuilder.build(
            mode: .replyDrafter,
            basePrompt: "BASE",
            services: [],
            episodicSummaries: [],
            now: Date()
        )
        XCTAssertTrue(prompt.contains("draft a reply"))
    }

    func testNoEpisodicSummariesOmitsRecentContextSection() {
        let prompt = PromptBuilder.build(
            mode: .summarizer,
            basePrompt: "BASE",
            services: ["telegram"],
            episodicSummaries: [],
            now: Date()
        )
        XCTAssertFalse(prompt.contains("Recent context:"))
    }

    // MARK: - New [service] header format

    func testSummarizerSuffixDocumentsServiceHeaderFormat() {
        let prompt = PromptBuilder.build(
            mode: .summarizer, basePrompt: "BASE",
            services: [], episodicSummaries: [], now: Date()
        )
        // The schema instructions must explain the [service] tag so the LLM extracts correctly.
        XCTAssertTrue(prompt.contains("[signal]") || prompt.contains("[service]"),
                      "Summarizer suffix must document the [service] header tag format")
        XCTAssertTrue(prompt.contains("conversationId"))
    }

    func testSummarizerSuffixExplainsIdExtraction() {
        let prompt = PromptBuilder.build(
            mode: .summarizer, basePrompt: "BASE",
            services: [], episodicSummaries: [], now: Date()
        )
        XCTAssertTrue(prompt.contains("[id="), "Suffix must explain [id= extraction rule")
    }

    func testDefaultPromptEnforcesEnglish() {
        XCTAssertTrue(
            PromptBuilder.defaultBasePrompt.lowercased().contains("english"),
            "Base prompt must instruct the LLM to write in English regardless of input language"
        )
    }

    func testDefaultPromptContainsHeadlineGoodExample() {
        // The concrete good/bad examples are key for prompt quality — guard them.
        XCTAssertTrue(
            PromptBuilder.defaultBasePrompt.contains("canceled") ||
            PromptBuilder.defaultBasePrompt.contains("cancelled") ||
            PromptBuilder.defaultBasePrompt.contains("Nagel"),
            "Base prompt must contain the headline good-example (Lasse Nagel canceled...)"
        )
    }

    // MARK: - Chat mode

    func testChatModeWithNoConversationsSaysNoneAvailable() {
        let prompt = PromptBuilder.build(
            mode: .chat(conversations: []), basePrompt: "BASE",
            services: [], episodicSummaries: [], now: Date()
        )
        XCTAssertTrue(prompt.contains("No conversations available"))
    }

    func testChatModeNumbersConversationsFrom1() {
        let prompt = PromptBuilder.build(
            mode: .chat(conversations: ["signal|abc|Alice", "telegram|xyz|Bob"]),
            basePrompt: "BASE", services: [], episodicSummaries: [], now: Date()
        )
        XCTAssertTrue(prompt.contains("1. signal|abc|Alice"))
        XCTAssertTrue(prompt.contains("2. telegram|xyz|Bob"))
    }

    func testChatModeSuffixContainsDraftAndChooseInstructions() {
        let prompt = PromptBuilder.build(
            mode: .chat(conversations: ["signal|abc|Alice"]),
            basePrompt: "BASE", services: [], episodicSummaries: [], now: Date()
        )
        XCTAssertTrue(prompt.contains("DRAFT:"))
        XCTAssertTrue(prompt.contains("CHOOSE"))
    }
}
