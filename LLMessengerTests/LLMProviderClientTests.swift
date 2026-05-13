// LLMessengerTests/LLMProviderClientTests.swift
import XCTest
@testable import LLMessenger

final class ProviderMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (URLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = ProviderMockURLProtocol.handler else {
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

final class LLMProviderClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        ProviderMockURLProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderMockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    private func ok(url: String, _ json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: url)!,
                         statusCode: 200, httpVersion: nil, headerFields: nil)!,
         Data(json.utf8))
    }

    private func status(
        url: String,
        code: Int,
        headers: [String: String] = [:],
        body: String = ""
    ) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: url)!,
                         statusCode: code, httpVersion: nil, headerFields: headers)!,
         Data(body.utf8))
    }

    private func requestBody(from request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else {
            guard let stream = request.httpBodyStream else {
                XCTFail("Expected request body")
                return [:]
            }

            stream.open()
            defer { stream.close() }

            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 {
                    throw stream.streamError ?? CocoaError(.fileReadUnknown)
                }
                if count == 0 {
                    break
                }
                collected.append(buffer, count: count)
            }
            data = collected
        }

        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func nonHTTP(url: String, body: String = "{}") -> (URLResponse, Data) {
        (URLResponse(url: URL(string: url)!,
                     mimeType: "application/json",
                     expectedContentLength: body.utf8.count,
                     textEncodingName: "utf-8"),
         Data(body.utf8))
    }

    func testOpenAIParsesStandardResponse() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.ok(
                url: "https://api.openai.com/v1/chat/completions",
                #"{"choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":7,"completion_tokens":2}}"#
            )
        }

        let client = OpenAIClient(apiKey: "test-key", session: session)
        let response = try await client.complete(model: "gpt-test", messages: [], maxTokens: 10)

        XCTAssertEqual(response.text, "OK")
        XCTAssertEqual(response.inputTokens, 7)
        XCTAssertEqual(response.outputTokens, 2)
    }

    func testOpenAIRequestContainsExpectedHeadersAndBody() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?
        ProviderMockURLProtocol.handler = { request in
            capturedRequest = request
            capturedBody = try self.requestBody(from: request)
            return self.ok(
                url: "https://api.openai.com/v1/chat/completions",
                #"{"choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#
            )
        }

        let client = OpenAIClient(apiKey: "test-key", session: session)
        _ = try await client.complete(model: "gpt-test", messages: [
            LLMMessage(role: .system, content: "system prompt"),
            LLMMessage(role: .user, content: "hello")
        ], maxTokens: 123)

        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(capturedBody?["model"] as? String, "gpt-test")
        XCTAssertEqual(capturedBody?["max_tokens"] as? Int, 123)
        let messages = try XCTUnwrap(capturedBody?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "system prompt")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "hello")
    }

    func testOpenAIMalformedJsonThrowsInvalidResponse() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.ok(url: "https://api.openai.com/v1/chat/completions", "not json")
        }

        let client = OpenAIClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "gpt-test", messages: [], maxTokens: 10)
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // pass
        }
    }

    func testOpenAITopLevelArrayThrowsInvalidResponse() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.ok(url: "https://api.openai.com/v1/chat/completions", #"[]"#)
        }

        let client = OpenAIClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "gpt-test", messages: [], maxTokens: 10)
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // pass
        }
    }

    func testOpenAIMissingRequiredFieldsThrowsInvalidResponse() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.ok(url: "https://api.openai.com/v1/chat/completions", #"{"choices":[]}"#)
        }

        let client = OpenAIClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "gpt-test", messages: [], maxTokens: 10)
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // pass
        }
    }

    func testOpenAINonHTTPResponseThrowsInvalidResponse() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.nonHTTP(url: "https://api.openai.com/v1/chat/completions")
        }

        let client = OpenAIClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "gpt-test", messages: [], maxTokens: 10)
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // pass
        }
    }

    func testOpenAIRateLimitThrowsRetryAfter() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.status(
                url: "https://api.openai.com/v1/chat/completions",
                code: 429,
                headers: ["retry-after": "30"]
            )
        }

        let client = OpenAIClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "gpt-test", messages: [], maxTokens: 10)
            XCTFail("Expected rateLimited")
        } catch LLMError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 30)
        }
    }

    func testOpenAIRateLimitWithInvalidRetryAfterThrowsNilRetryAfter() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.status(
                url: "https://api.openai.com/v1/chat/completions",
                code: 429,
                headers: ["retry-after": "soon"]
            )
        }

        let client = OpenAIClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "gpt-test", messages: [], maxTokens: 10)
            XCTFail("Expected rateLimited")
        } catch LLMError.rateLimited(let retryAfter) {
            XCTAssertNil(retryAfter)
        }
    }

    func testOpenAIProviderErrorIncludesStatusAndBody() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.status(
                url: "https://api.openai.com/v1/chat/completions",
                code: 500,
                body: "server exploded"
            )
        }

        let client = OpenAIClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "gpt-test", messages: [], maxTokens: 10)
            XCTFail("Expected providerError")
        } catch LLMError.providerError(let message) {
            XCTAssertTrue(message.contains("500"))
            XCTAssertTrue(message.contains("server exploded"))
        }
    }

    func testOpenAINetworkFailureThrowsNetworkFailed() async throws {
        ProviderMockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let client = OpenAIClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "gpt-test", messages: [], maxTokens: 10)
            XCTFail("Expected networkFailed")
        } catch LLMError.networkFailed {
            // pass
        }
    }

    func testOpenAIConcurrentRequestsDoNotCrossTalk() async throws {
        let lock = NSLock()
        var requestCount = 0
        ProviderMockURLProtocol.handler = { request in
            let body = try self.requestBody(from: request)
            let model = try XCTUnwrap(body["model"] as? String)
            lock.lock()
            requestCount += 1
            lock.unlock()
            return self.ok(
                url: "https://api.openai.com/v1/chat/completions",
                #"{"choices":[{"message":{"content":"\#(model)"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#
            )
        }

        let client = OpenAIClient(apiKey: "test-key", session: session)
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let response = try await client.complete(
                        model: "gpt-\(i)",
                        messages: [LLMMessage(role: .user, content: "hello \(i)")],
                        maxTokens: 10
                    )
                    return response.text
                }
            }

            var seen = Set<String>()
            for try await text in group {
                seen.insert(text)
            }
            XCTAssertEqual(seen.count, 50)
        }

        lock.lock()
        let finalRequestCount = requestCount
        lock.unlock()
        XCTAssertEqual(finalRequestCount, 50)
    }

    func testAnthropicParsesStandardResponse() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.ok(
                url: "https://api.anthropic.com/v1/messages",
                #"{"content":[{"type":"text","text":"OK"}],"usage":{"input_tokens":7,"output_tokens":2}}"#
            )
        }

        let client = AnthropicClient(apiKey: "test-key", session: session)
        let response = try await client.complete(model: "claude-test", messages: [], maxTokens: 10)

        XCTAssertEqual(response.text, "OK")
        XCTAssertEqual(response.inputTokens, 7)
        XCTAssertEqual(response.outputTokens, 2)
    }

    func testAnthropicRequestContainsExpectedHeadersAndBody() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?
        ProviderMockURLProtocol.handler = { request in
            capturedRequest = request
            capturedBody = try self.requestBody(from: request)
            return self.ok(
                url: "https://api.anthropic.com/v1/messages",
                #"{"content":[{"type":"text","text":"OK"}],"usage":{"input_tokens":1,"output_tokens":1}}"#
            )
        }

        let client = AnthropicClient(apiKey: "test-key", session: session)
        _ = try await client.complete(model: "claude-test", messages: [
            LLMMessage(role: .system, content: "system prompt"),
            LLMMessage(role: .user, content: "hello"),
            LLMMessage(role: .assistant, content: "hi")
        ], maxTokens: 123)

        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(capturedBody?["model"] as? String, "claude-test")
        XCTAssertEqual(capturedBody?["max_tokens"] as? Int, 123)
        XCTAssertEqual(capturedBody?["system"] as? String, "system prompt")
        let messages = try XCTUnwrap(capturedBody?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hello")
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages[1]["content"] as? String, "hi")
    }

    func testAnthropicMalformedJsonThrowsInvalidResponse() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.ok(url: "https://api.anthropic.com/v1/messages", "not json")
        }

        let client = AnthropicClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "claude-test", messages: [], maxTokens: 10)
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // pass
        }
    }

    func testAnthropicTopLevelArrayThrowsInvalidResponse() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.ok(url: "https://api.anthropic.com/v1/messages", #"[]"#)
        }

        let client = AnthropicClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "claude-test", messages: [], maxTokens: 10)
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // pass
        }
    }

    func testAnthropicMissingRequiredFieldsThrowsInvalidResponse() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.ok(url: "https://api.anthropic.com/v1/messages", #"{"content":[]}"#)
        }

        let client = AnthropicClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "claude-test", messages: [], maxTokens: 10)
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // pass
        }
    }

    func testAnthropicNonHTTPResponseThrowsInvalidResponse() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.nonHTTP(url: "https://api.anthropic.com/v1/messages")
        }

        let client = AnthropicClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "claude-test", messages: [], maxTokens: 10)
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // pass
        }
    }

    func testAnthropicRateLimitThrowsRetryAfter() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.status(
                url: "https://api.anthropic.com/v1/messages",
                code: 429,
                headers: ["retry-after": "30"]
            )
        }

        let client = AnthropicClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "claude-test", messages: [], maxTokens: 10)
            XCTFail("Expected rateLimited")
        } catch LLMError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 30)
        }
    }

    func testAnthropicRateLimitWithInvalidRetryAfterThrowsNilRetryAfter() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.status(
                url: "https://api.anthropic.com/v1/messages",
                code: 429,
                headers: ["retry-after": "soon"]
            )
        }

        let client = AnthropicClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "claude-test", messages: [], maxTokens: 10)
            XCTFail("Expected rateLimited")
        } catch LLMError.rateLimited(let retryAfter) {
            XCTAssertNil(retryAfter)
        }
    }

    func testAnthropicProviderErrorIncludesStatusAndBody() async throws {
        ProviderMockURLProtocol.handler = { _ in
            self.status(
                url: "https://api.anthropic.com/v1/messages",
                code: 500,
                body: "server exploded"
            )
        }

        let client = AnthropicClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "claude-test", messages: [], maxTokens: 10)
            XCTFail("Expected providerError")
        } catch LLMError.providerError(let message) {
            XCTAssertTrue(message.contains("500"))
            XCTAssertTrue(message.contains("server exploded"))
        }
    }

    func testAnthropicNetworkFailureThrowsNetworkFailed() async throws {
        ProviderMockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let client = AnthropicClient(apiKey: "test-key", session: session)

        do {
            _ = try await client.complete(model: "claude-test", messages: [], maxTokens: 10)
            XCTFail("Expected networkFailed")
        } catch LLMError.networkFailed {
            // pass
        }
    }

    func testAnthropicConcurrentRequestsDoNotCrossTalk() async throws {
        let lock = NSLock()
        var requestCount = 0
        ProviderMockURLProtocol.handler = { request in
            let body = try self.requestBody(from: request)
            let model = try XCTUnwrap(body["model"] as? String)
            lock.lock()
            requestCount += 1
            lock.unlock()
            return self.ok(
                url: "https://api.anthropic.com/v1/messages",
                #"{"content":[{"type":"text","text":"\#(model)"}],"usage":{"input_tokens":1,"output_tokens":1}}"#
            )
        }

        let client = AnthropicClient(apiKey: "test-key", session: session)
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let response = try await client.complete(
                        model: "claude-\(i)",
                        messages: [LLMMessage(role: .user, content: "hello \(i)")],
                        maxTokens: 10
                    )
                    return response.text
                }
            }

            var seen = Set<String>()
            for try await text in group {
                seen.insert(text)
            }
            XCTAssertEqual(seen.count, 50)
        }

        lock.lock()
        let finalRequestCount = requestCount
        lock.unlock()
        XCTAssertEqual(finalRequestCount, 50)
    }
}
