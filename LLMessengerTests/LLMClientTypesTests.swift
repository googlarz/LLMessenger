// LLMessengerTests/LLMClientTypesTests.swift
import XCTest
@testable import LLMessenger

final class LLMClientTypesTests: XCTestCase {

    func testLLMMessageRoles() {
        let sys = LLMMessage(role: .system, content: "be brief")
        let usr = LLMMessage(role: .user, content: "hello")
        XCTAssertEqual(sys.role, .system)
        XCTAssertEqual(usr.role, .user)
    }

    func testLLMResponseHoldsText() {
        let r = LLMResponse(text: "ok", inputTokens: 5, outputTokens: 1)
        XCTAssertEqual(r.text, "ok")
        XCTAssertEqual(r.inputTokens, 5)
        XCTAssertEqual(r.outputTokens, 1)
    }

    func testLLMErrorDescriptions() {
        XCTAssertNotNil(LLMError.networkFailed("timeout").errorDescription)
        XCTAssertNotNil(LLMError.invalidResponse.errorDescription)
        XCTAssertNotNil(LLMError.missingAPIKey.errorDescription)
        XCTAssertNotNil(LLMError.providerError("rate limit").errorDescription)
    }
}
