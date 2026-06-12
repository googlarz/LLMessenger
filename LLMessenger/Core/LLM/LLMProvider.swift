// LLMessenger/Core/LLM/LLMProvider.swift
import Foundation

enum LLMProvider: String, CaseIterable {
    case appleIntelligence = "apple"
    case anthropic
    case openai
    case ollama

    /// Providers selectable on this machine. Apple's on-device model only
    /// appears when the OS and hardware actually support it.
    static var availableCases: [LLMProvider] {
        allCases.filter { $0 != .appleIntelligence || AppleFM.isAvailable }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .openai:          return true
        case .ollama, .appleIntelligence:  return false
        }
    }

    var defaultModel: String {
        switch self {
        case .appleIntelligence: return "system"
        case .anthropic: return "claude-sonnet-4-6"
        case .openai:    return "gpt-4o-mini"
        case .ollama:    return "llama3.1"
        }
    }

    var displayName: String {
        switch self {
        case .appleIntelligence: return "On-Device"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .ollama: return "Ollama"
        }
    }

    var isCloud: Bool {
        switch self {
        case .anthropic, .openai: return true
        case .ollama, .appleIntelligence: return false
        }
    }

    func makeClient(apiKey: String?) -> LLMClient {
        switch self {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) { return AppleFMClient() }
            #endif
            return UnconfiguredLLMClient()
        case .anthropic: return AnthropicClient(apiKey: apiKey ?? "")
        case .openai:    return OpenAIClient(apiKey: apiKey ?? "")
        case .ollama:    return OllamaClient()
        }
    }
}
