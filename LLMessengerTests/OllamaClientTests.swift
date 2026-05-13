// LLMessengerTests/OllamaClientTests.swift
import XCTest
@testable import LLMessenger

// MARK: - URLProtocol stub

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class OllamaClientTests: XCTestCase {

    private var sut: OllamaClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        sut = OllamaClient(baseURL: URL(string: "http://localhost:11434")!, session: session)
    }

    // MARK: Helpers

    private func ok(_ json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!,
                         statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private func status(_ code: Int, headers: [String: String] = [:], body: String = "") -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!,
                         statusCode: code, httpVersion: nil, headerFields: headers)!, Data(body.utf8))
    }

    private func requestBody(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            XCTFail("Expected request body")
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    // MARK: - Response parsing

    func testParsesStandardResponse() async throws {
        MockURLProtocol.handler = { _ in
            self.ok(#"{"message":{"role":"assistant","content":"OK"},"prompt_eval_count":5,"eval_count":3}"#)
        }
        let r = try await sut.complete(model: "m", messages: [], maxTokens: 10)
        XCTAssertEqual(r.text, "OK")
        XCTAssertEqual(r.inputTokens, 5)
        XCTAssertEqual(r.outputTokens, 3)
    }

    func testParsesThinkingModelResponse() async throws {
        // gemma4 returns both "content" and "thinking" — only "content" should be used.
        MockURLProtocol.handler = { _ in
            self.ok(#"{"message":{"role":"assistant","content":"42","thinking":"Let me think..."},"prompt_eval_count":100,"eval_count":20}"#)
        }
        let r = try await sut.complete(model: "gemma4", messages: [], maxTokens: 200)
        XCTAssertEqual(r.text, "42")
        XCTAssertEqual(r.inputTokens, 100)
        XCTAssertEqual(r.outputTokens, 20)
    }

    func testMissingEvalCountsDefaultToZero() async throws {
        MockURLProtocol.handler = { _ in
            self.ok(#"{"message":{"role":"assistant","content":"hi"}}"#)
        }
        let r = try await sut.complete(model: "m", messages: [], maxTokens: 5)
        XCTAssertEqual(r.inputTokens, 0)
        XCTAssertEqual(r.outputTokens, 0)
    }

    // MARK: - Error cases

    func testRateLimitedThrowsWithRetryAfter() async throws {
        MockURLProtocol.handler = { _ in
            self.status(429, headers: ["retry-after": "60"])
        }
        do {
            _ = try await sut.complete(model: "m", messages: [], maxTokens: 5)
            XCTFail("Expected rateLimited error")
        } catch LLMError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 60)
        }
    }

    func testRateLimitedWithNoRetryAfterHeader() async throws {
        MockURLProtocol.handler = { _ in self.status(429) }
        do {
            _ = try await sut.complete(model: "m", messages: [], maxTokens: 5)
            XCTFail("Expected rateLimited error")
        } catch LLMError.rateLimited(let retryAfter) {
            XCTAssertNil(retryAfter)
        }
    }

    func testHttp500ThrowsProviderError() async throws {
        MockURLProtocol.handler = { _ in self.status(500, body: "Internal Server Error") }
        do {
            _ = try await sut.complete(model: "m", messages: [], maxTokens: 5)
            XCTFail("Expected providerError")
        } catch LLMError.providerError(let msg) {
            XCTAssertTrue(msg.contains("500"), "Error message should include status code, got: \(msg)")
        }
    }

    func testMalformedJsonThrowsInvalidResponse() async throws {
        MockURLProtocol.handler = { _ in self.ok("not json at all") }
        do {
            _ = try await sut.complete(model: "m", messages: [], maxTokens: 5)
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // pass
        }
    }

    func testMissingMessageKeyThrowsInvalidResponse() async throws {
        MockURLProtocol.handler = { _ in self.ok(#"{"done":true}"#) }
        do {
            _ = try await sut.complete(model: "m", messages: [], maxTokens: 5)
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // pass
        }
    }

    func testNetworkFailureThrowsNetworkFailed() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await sut.complete(model: "m", messages: [], maxTokens: 5)
            XCTFail("Expected networkFailed error")
        } catch LLMError.networkFailed {
            // pass
        }
    }

    // MARK: - Request body shape (regression guards)

    func testNumPredictIsNotSentInRequestBody() async throws {
        // Regression: num_predict was previously set to maxTokens, which starved
        // thinking-model tokens (gemma4 uses ~1500+ tokens for reasoning before
        // emitting the actual response, leaving nothing for the content field).
        var captured: [String: Any]?
        MockURLProtocol.handler = { request in
            captured = try JSONSerialization.jsonObject(with: self.requestBody(from: request)) as? [String: Any]
            return self.ok(#"{"message":{"role":"assistant","content":"ok"}}"#)
        }
        _ = try? await sut.complete(model: "m", messages: [], maxTokens: 4000)
        let options = captured?["options"] as? [String: Any]
        XCTAssertNil(options?["num_predict"],
                     "num_predict must not be sent — it starves thinking-model token budget")
    }

    func testNumCtxIs16384() async throws {
        var captured: [String: Any]?
        MockURLProtocol.handler = { request in
            captured = try JSONSerialization.jsonObject(with: self.requestBody(from: request)) as? [String: Any]
            return self.ok(#"{"message":{"role":"assistant","content":"ok"}}"#)
        }
        _ = try? await sut.complete(model: "m", messages: [], maxTokens: 10)
        let options = captured?["options"] as? [String: Any]
        XCTAssertEqual(options?["num_ctx"] as? Int, 16384)
    }

    func testRequestBodyContainsModelAndStream() async throws {
        var captured: [String: Any]?
        MockURLProtocol.handler = { request in
            captured = try JSONSerialization.jsonObject(with: self.requestBody(from: request)) as? [String: Any]
            return self.ok(#"{"message":{"role":"assistant","content":"ok"}}"#)
        }
        _ = try? await sut.complete(model: "gemma4", messages: [
            LLMMessage(role: .system, content: "be brief"),
            LLMMessage(role: .user, content: "hello")
        ], maxTokens: 10)

        XCTAssertEqual(captured?["model"] as? String, "gemma4")
        XCTAssertEqual(captured?["stream"] as? Bool, false)
        let messages = captured?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        XCTAssertEqual(messages?.last?["role"] as? String, "user")
    }
}
