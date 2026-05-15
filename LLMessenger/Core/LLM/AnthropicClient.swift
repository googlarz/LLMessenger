// LLMessenger/Core/LLM/AnthropicClient.swift
import Foundation

final class AnthropicClient: LLMClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        // Opt-in pre-send sanitization redacts CC/SSN/IBAN/email patterns before they
        // leave the machine. Off by default; see SettingsRepository.loadSanitizeBeforeSend.
        let outgoing = SettingsRepository().loadSanitizeBeforeSend()
            ? MessageSanitizer.sanitize(messages)
            : messages
        let systemContent = outgoing.first { $0.role == .system }?.content ?? ""
        let chatMessages = outgoing.filter { $0.role != .system }.map { msg -> [String: Any] in
            ["role": msg.role == .user ? "user" : "assistant", "content": msg.content]
        }

        var body: [String: Any] = [
            "model":      model,
            "max_tokens": maxTokens,
            "messages":   chatMessages
        ]
        if !systemContent.isEmpty { body["system"] = systemContent }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            NetworkAuditLog.shared.record(provider: "Anthropic", request: request,
                                          status: nil, durationMs: ms, error: error)
            throw LLMError.networkFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        NetworkAuditLog.shared.record(provider: "Anthropic", request: request,
                                      status: http.statusCode, durationMs: durationMs, error: nil)
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
              let contentArr = json["content"] as? [[String: Any]],
              let text = contentArr.first?["text"] as? String,
              let usage = json["usage"] as? [String: Any] else {
            throw LLMError.invalidResponse
        }

        return LLMResponse(
            text: text,
            inputTokens:  usage["input_tokens"]  as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0
        )
    }
}
