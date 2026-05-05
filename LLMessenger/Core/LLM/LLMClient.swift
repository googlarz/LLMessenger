// LLMessenger/Core/LLM/LLMClient.swift
import Foundation

struct LLMMessage: Equatable {
    enum Role: String { case system, user, assistant }
    let role: Role
    let content: String
}

struct LLMResponse: Equatable {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
}

enum LLMError: Error, LocalizedError {
    case networkFailed(String)
    case invalidResponse
    case missingAPIKey
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .networkFailed(let r): return "Network failed: \(r)"
        case .invalidResponse:      return "Invalid response from LLM provider"
        case .missingAPIKey:        return "Missing API key"
        case .providerError(let r): return "Provider error: \(r)"
        }
    }
}

protocol LLMClient {
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse
}
