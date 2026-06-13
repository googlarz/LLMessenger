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
    case rateLimited(retryAfter: Int?)

    var errorDescription: String? {
        switch self {
        case .networkFailed(let r):       return "Network failed: \(r)"
        case .invalidResponse:            return "Invalid response from LLM provider"
        case .missingAPIKey:              return "Missing API key"
        case .providerError(let r):       return "Provider error: \(r)"
        case .rateLimited(let s):
            if let s { return "Rate limited — retry after \(s)s" }
            return "Rate limited"
        }
    }
}

protocol LLMClient {
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse
    /// True when the client runs entirely on-device (Ollama, Apple Foundation Models).
    /// Cloud clients (OpenAI, Anthropic) return false. Used to enforce per-conversation
    /// `local_only` privacy overrides at the dispatch boundary.
    var isLocal: Bool { get }
}

extension LLMClient {
    var isLocal: Bool { false }
    var isCloud: Bool { !isLocal }
}

struct UnconfiguredLLMClient: LLMClient {
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        throw LLMError.providerError("Choose an AI backend in Settings before generating briefs.")
    }
}
