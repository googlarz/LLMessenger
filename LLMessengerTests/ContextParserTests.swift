// LLMessengerTests/ContextParserTests.swift
import XCTest
@testable import LLMessenger

private final class StubLLMClient: LLMClient {
    var stubbedResponse: String
    init(_ response: String) { self.stubbedResponse = response }
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        LLMResponse(text: stubbedResponse, inputTokens: 1, outputTokens: 1)
    }
}

final class ContextParserTests: XCTestCase {

    func testParsesFieldsFromJSON() async throws {
        let json = """
        ```json
        {
          "relationship": "son's basketball team",
          "importantTopics": ["training", "games"],
          "noiseTopics": ["banter"],
          "keySenders": ["Coach Lasse"],
          "priorityHint": "high",
          "contextNote": "flag coach posts",
          "responseExpectation": "evening ok"
        }
        ```
        """
        let parser = ContextParser(llmClient: StubLLMClient(json))
        let ctx = try await parser.parse(
            sentence: "this is my son's basketball team",
            service: "signal", conversationId: "c1", existing: nil, model: "m"
        )
        XCTAssertEqual(ctx.service, "signal")
        XCTAssertEqual(ctx.conversationId, "c1")
        XCTAssertEqual(ctx.relationship, "son's basketball team")
        XCTAssertEqual(ctx.importantTopicsList, ["training", "games"])
        XCTAssertEqual(ctx.noiseTopicsList, ["banter"])
        XCTAssertEqual(ctx.keySendersList, ["Coach Lasse"])
        XCTAssertEqual(ctx.priorityHint, "high")
        XCTAssertEqual(ctx.contextNote, "flag coach posts")
        XCTAssertEqual(ctx.responseExpectation, "evening ok")
    }

    func testMergePreservesExistingFields() async throws {
        var existing = ConversationContext(
            service: "signal", conversationId: "c1", label: "Team",
            priorityHint: "low", updatedAt: Date(),
            relationship: "old rel", contextNote: "old note",
            privacyOverride: "local_only"
        )
        existing.keySendersList = ["Old Sender"]

        // Parsed response only sets importantTopics; everything else empty/absent.
        let json = #"{"importantTopics":["deploy"],"noiseTopics":[],"keySenders":[],"priorityHint":"auto","relationship":"","contextNote":"","responseExpectation":""}"#
        let parser = ContextParser(llmClient: StubLLMClient(json))
        let ctx = try await parser.parse(
            sentence: "flag deploys", service: "signal", conversationId: "c1",
            existing: existing, model: "m"
        )

        XCTAssertEqual(ctx.importantTopicsList, ["deploy"])      // updated
        XCTAssertEqual(ctx.relationship, "old rel")             // preserved (empty parsed)
        XCTAssertEqual(ctx.contextNote, "old note")             // preserved
        XCTAssertEqual(ctx.keySendersList, ["Old Sender"])      // preserved (empty parsed)
        XCTAssertEqual(ctx.privacyOverride, "local_only")       // never parsed, preserved
        XCTAssertEqual(ctx.label, "Team")                       // preserved
        XCTAssertEqual(ctx.priorityHint, "auto")               // parsed wins
    }
}
