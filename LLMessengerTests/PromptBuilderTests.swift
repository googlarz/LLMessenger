// LLMessengerTests/PromptBuilderTests.swift
import XCTest
@testable import LLMessenger

final class PromptBuilderTests: XCTestCase {

    func testDefaultBasePromptContainsCoreInstructions() {
        let prompt = PromptBuilder.defaultBasePrompt
        XCTAssertTrue(prompt.contains("personal messaging assistant"))
        XCTAssertTrue(prompt.contains("Never send anything without explicit user confirmation"))
    }

    func testBuildSummarizerPromptInjectsContext() {
        let prompt = PromptBuilder.build(
            mode: .summarizer,
            basePrompt: "BASE",
            services: ["telegram", "signal"],
            episodicSummaries: ["Yesterday: Marta asked about deploy.", "Today: João confirmed staging fix."],
            now: Date(timeIntervalSince1970: 1_746_465_600)
        )
        XCTAssertTrue(prompt.contains("BASE"))
        XCTAssertTrue(prompt.contains("telegram"))
        XCTAssertTrue(prompt.contains("signal"))
        XCTAssertTrue(prompt.contains("Marta asked about deploy"))
        XCTAssertTrue(prompt.contains("Summarize"))
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
}
