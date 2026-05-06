// LLMessenger/Core/LLM/LLMProvider.swift
import Foundation

enum LLMProvider: String, CaseIterable {
    case anthropic
    case openai
    case ollama

    var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .openai: return true
        case .ollama:             return false
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-6"
        case .openai:    return "gpt-4o-mini"
        case .ollama:    return "llama3.1"
        }
    }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .ollama: return "Ollama"
        }
    }

    var isCloud: Bool {
        switch self {
        case .anthropic, .openai: return true
        case .ollama: return false
        }
    }

    func makeClient(apiKey: String?) -> LLMClient {
        switch self {
        case .anthropic: return AnthropicClient(apiKey: apiKey ?? "")
        case .openai:    return OpenAIClient(apiKey: apiKey ?? "")
        case .ollama:    return OllamaClient()
        }
    }
}
