// LLMessenger/Core/LLM/LLMClient.swift
import Foundation

struct LLMMessage: Equatable, Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    let role: Role
    let content: String
}

struct LLMResponse: Equatable, Sendable {
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
    case egressBlocked

    var errorDescription: String? {
        switch self {
        case .networkFailed(let r):       return "Network failed: \(r)"
        case .invalidResponse:            return "Invalid response from LLM provider"
        case .missingAPIKey:              return "Missing API key"
        case .providerError(let r):       return "Provider error: \(r)"
        case .rateLimited(let s):
            if let s { return "Rate limited — retry after \(s)s" }
            return "Rate limited"
        case .egressBlocked:              return "Cloud AI request blocked by local-only mode"
        }
    }
}

protocol LLMClient: Sendable {
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse
    /// True when the client runs entirely on-device (Ollama, Apple Foundation Models).
    /// Cloud clients (OpenAI, Anthropic) return false. Used to enforce per-conversation
    /// `local_only` privacy overrides at the dispatch boundary.
    var isLocal: Bool { get }
}

enum LLMRequestPurpose: String, Sendable {
    case unspecified
    case briefSummarization = "brief_summarization"
    case memoryCompression = "memory_compression"
    case commandRouting = "command_routing"
    case intentRouting = "intent_routing"
    case contextParsing = "context_parsing"
    case commitmentExtraction = "commitment_extraction"
    case realtimeTriage = "realtime_triage"
    case scheduleDetection = "schedule_detection"
    case agentReplyDraft = "agent_reply_draft"
    case chatAnswer = "chat_answer"
    case replyRevision = "reply_revision"
    case quickReply = "quick_reply"
    case replyDraft = "reply_draft"
    case settingsConnection = "settings_connection"
}

struct LLMInvocationMetadata: Sendable {
    let purpose: LLMRequestPurpose
    let briefId: Int64?
    let service: String?
    let conversationId: String?

    static let unspecified = LLMInvocationMetadata(
        purpose: .unspecified,
        briefId: nil,
        service: nil,
        conversationId: nil
    )
}

enum LLMInvocationContext {
    @TaskLocal static var metadata: LLMInvocationMetadata = .unspecified
}

extension LLMClient {
    var isLocal: Bool { false }
    var isCloud: Bool { !isLocal }

    func complete(
        model: String,
        messages: [LLMMessage],
        maxTokens: Int,
        purpose: LLMRequestPurpose,
        briefId: Int64? = nil,
        service: String? = nil,
        conversationId: String? = nil
    ) async throws -> LLMResponse {
        let metadata = LLMInvocationMetadata(
            purpose: purpose,
            briefId: briefId,
            service: service,
            conversationId: conversationId
        )
        return try await LLMInvocationContext.$metadata.withValue(metadata) {
            try await complete(model: model, messages: messages, maxTokens: maxTokens)
        }
    }
}

struct UnconfiguredLLMClient: LLMClient {
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        throw LLMError.providerError("Choose an AI backend in Settings before generating briefs.")
    }
}
