// LLMessengerTests/LLMProviderTests.swift
import XCTest
@testable import LLMessenger

final class LLMProviderTests: XCTestCase {

    func testProviderRawValues() {
        XCTAssertEqual(LLMProvider.anthropic.rawValue, "anthropic")
        XCTAssertEqual(LLMProvider.openai.rawValue,    "openai")
        XCTAssertEqual(LLMProvider.ollama.rawValue,    "ollama")
    }

    func testMakeClientAnthropic() {
        let client = LLMProvider.anthropic.makeClient(apiKey: "sk-ant-test")
        XCTAssertTrue(client is AnthropicClient)
    }

    func testMakeClientOpenAI() {
        let client = LLMProvider.openai.makeClient(apiKey: "sk-openai-test")
        XCTAssertTrue(client is OpenAIClient)
    }

    func testMakeClientOllamaIgnoresKey() {
        let client = LLMProvider.ollama.makeClient(apiKey: nil)
        XCTAssertTrue(client is OllamaClient)
    }
}
