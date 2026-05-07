// LLMessenger/Core/LLM/OllamaClient.swift
import Foundation

final class OllamaClient: LLMClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://localhost:11434")!,
         session: URLSession = {
             let config = URLSessionConfiguration.default
             config.timeoutIntervalForRequest = 300
             return URLSession(configuration: config)
         }()) {
        self.baseURL = baseURL
        self.session = session
    }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        let chatMessages = messages.map { msg -> [String: Any] in
            ["role": msg.role.rawValue, "content": msg.content]
        }

        let body: [String: Any] = [
            "model":    model,
            "messages": chatMessages,
            "stream":   false,
            // num_predict is intentionally omitted for Ollama — local models have no
            // billing concern, and thinking models (e.g. gemma4) need the full context
            // window for their reasoning pass before they can emit the final response.
            // num_ctx is bumped to 16 384 to handle longer conversation inputs.
            "options":  ["num_ctx": 16384]
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.networkFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) }
            throw LLMError.rateLimited(retryAfter: retryAfter)
        }
        if http.statusCode >= 400 {
            throw LLMError.providerError("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.invalidResponse
        }

        return LLMResponse(
            text: text,
            inputTokens:  json["prompt_eval_count"] as? Int ?? 0,
            outputTokens: json["eval_count"]        as? Int ?? 0
        )
    }
}
