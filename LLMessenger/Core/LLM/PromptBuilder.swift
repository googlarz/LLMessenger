// LLMessenger/Core/LLM/PromptBuilder.swift
import Foundation

enum LLMMode {
    case summarizer
    case conversationalist
    case replyDrafter
    case compressor
}

struct PromptBuilder {

    static let defaultBasePrompt = """
    You are a personal messaging assistant. You have access to the user's messages \
    from their connected services. Your job is to:
    - Summarize new messages clearly and concisely
    - Surface action items explicitly
    - Answer questions about message content
    - Draft replies in the user's voice when asked
    - Never send anything without explicit user confirmation
    """

    static func build(
        mode: LLMMode,
        basePrompt: String,
        services: [String],
        episodicSummaries: [String],
        now: Date
    ) -> String {
        var parts: [String] = [basePrompt]

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        parts.append("Current date: \(dateFormatter.string(from: now))")

        if !services.isEmpty {
            parts.append("Connected services: \(services.joined(separator: ", "))")
        }

        if !episodicSummaries.isEmpty {
            parts.append("Recent context:")
            for s in episodicSummaries {
                parts.append("- \(s)")
            }
        }

        parts.append(suffix(for: mode))
        return parts.joined(separator: "\n")
    }

    private static func suffix(for mode: LLMMode) -> String {
        switch mode {
        case .summarizer:
            return "Summarize the new messages below. Group by conversation. Surface action items."
        case .conversationalist:
            return "Answer the user's questions about the messages. Be concise."
        case .replyDrafter:
            return "Given the conversation thread and the user's intent, draft a reply in their voice."
        case .compressor:
            return "Summarize the entire conversation above in 2-3 sentences. Focus on outcomes and open threads."
        }
    }
}
