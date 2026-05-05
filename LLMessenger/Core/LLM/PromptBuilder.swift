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
    You are a personal messaging assistant. You read messages from Signal, Telegram, \
    and other services and produce clear, structured briefs. Your job is to:
    - Produce structured summaries with timeline, action items, and key observations
    - Surface action items explicitly with owner and status
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
            return """
            Produce a structured brief for the messages below. Use this exact format:

            ## [Group/Chat Name] – Summary

            **Platform:** [service] | **Group:** [name if group chat, or sender name if DM]

            ---

            ### Timeline of Key Events

            **[Date, e.g. Mon, 5 May]**
            - [Key event or decision, one bullet per distinct topic]

            (Repeat for each date that has messages)

            ---

            ### ⚡ Action Items

            | # | Action | Owner | Status |
            |---|--------|-------|--------|
            | 1 | [Clear action description] | [Person responsible] | ⚠️ Pending / ✅ Done |

            (Omit this section if there are no action items)

            ---

            ### 🔔 Notable Notes
            - [Anything important: departures, venue changes, last-minute updates, warnings]

            Rules:
            - Use the actual sender names from the messages, not placeholders
            - Group messages by date using the timestamps provided
            - Be specific — include names, times, locations, and numbers when mentioned
            - Omit sections that have no content (e.g. no action items → skip that section)
            - Write in English even if the messages are in another language
            """
        case .conversationalist:
            return "Answer the user's questions about the messages. Be concise."
        case .replyDrafter:
            return "Given the conversation thread and the user's intent, draft a reply in their voice."
        case .compressor:
            return "Summarize the entire conversation above in 2-3 sentences. Focus on outcomes and open threads."
        }
    }
}
