// LLMessenger/Core/LLM/OllamaClient.swift
import Foundation

final class OllamaClient: LLMClient {
    var isLocal: Bool { true }
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
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
            // Keep local briefs responsive while still leaving room for bounded context.
            "options":  ["num_ctx": 16384]
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            NetworkAuditLog.shared.record(provider: "Ollama (local)", request: request,
                                          status: nil, durationMs: ms, error: error)
            if let urlErr = error as? URLError,
               [.cannotConnectToHost, .networkConnectionLost, .timedOut].contains(urlErr.code) {
                throw LLMError.networkFailed("Ollama server not reachable — is it running?")
            }
            throw LLMError.networkFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        NetworkAuditLog.shared.record(provider: "Ollama (local)", request: request,
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

// MARK: - Model listing

struct OllamaModel: Decodable, Identifiable {
    let name: String
    let size: Int64

    var id: String { name }

    var displayLabel: String {
        let gb = Double(size) / 1_073_741_824
        return String(format: "%@ (%.1f GB)", name, gb)
    }
}

extension OllamaClient {
    /// Fetches the list of locally-pulled Ollama models.
    /// Throws if Ollama is not running or returns unexpected data.
    static func fetchModels(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) async throws -> [OllamaModel] {
        struct TagsResponse: Decodable { let models: [OllamaModel] }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(TagsResponse.self, from: data).models
    }
}
