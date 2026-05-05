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
    and other services and produce structured briefs. Your job is to:
    - Produce per-conversation JSON cards with headlines, summaries, and action items
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
            parts.append("Recent context from prior hours:")
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
            Produce a JSON brief for the messages below. Output ONLY valid JSON — no prose, no markdown fences, no explanation.

            Schema:
            {
              "total_messages": <int>,
              "total_threads": <int>,
              "total_people": <int>,
              "cards": [
                {
                  "service": "<imessage|telegram|signal>",
                  "conversation": "<conversation or group name>",
                  "headline": "<one-line summary of what happened — be specific and concrete>",
                  "priority": "<high|med|low>",
                  "counts": {"messages": <int>, "threads": <int>, "people": <int>},
                  "summary": "<2-3 sentence prose summary, plain text, no markdown>",
                  "callback": "<reference to prior context from the Recent context section, or null if none>",
                  "actions": ["<action item>"],
                  "quotes": [
                    {"from": "<sender name>", "time": "<HH:mm>", "text": "<verbatim or near-verbatim quote>"}
                  ]
                }
              ]
            }

            Rules:
            - One card per distinct conversation or group
            - Group all messages from the same conversationId into one card
            - priority: "high" = needs a reply, "med" = good to know, "low" = FYI
            - actions: concrete next steps for the user, max 3; empty array [] if none
            - quotes: 1-3 representative messages with actual HH:mm timestamps; omit [] if no good quotes
            - callback: only fill if the episodic context contains a directly relevant prior thread; otherwise null
            - summary: plain prose, no markdown formatting
            - Write in English
            """
        case .conversationalist:
            return "Answer the user's questions about the messages. Be concise and direct."
        case .replyDrafter:
            return "Given the conversation thread and the user's intent, draft a reply in their voice. Be natural."
        case .compressor:
            return "Summarize the entire conversation above in 2-3 sentences. Focus on outcomes and open threads."
        }
    }
}
