// LLMessenger/Core/LLM/OpenAIClient.swift
import Foundation

final class OpenAIClient: LLMClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        let chatMessages = messages.map { msg -> [String: Any] in
            ["role": msg.role.rawValue, "content": msg.content]
        }

        let body: [String: Any] = [
            "model":      model,
            "max_tokens": maxTokens,
            "messages":   chatMessages
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LLMError.invalidResponse
        }

        guard let json = jsonObject as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String,
              let usage = json["usage"] as? [String: Any] else {
            throw LLMError.invalidResponse
        }

        return LLMResponse(
            text: text,
            inputTokens:  usage["prompt_tokens"]     as? Int ?? 0,
            outputTokens: usage["completion_tokens"] as? Int ?? 0
        )
    }
}
