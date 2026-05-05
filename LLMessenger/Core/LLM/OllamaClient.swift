// LLMessenger/Core/LLM/OllamaClient.swift
import Foundation

final class OllamaClient: LLMClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://localhost:11434")!,
         session: URLSession = .shared) {
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
            "options":  ["num_predict": maxTokens]
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
