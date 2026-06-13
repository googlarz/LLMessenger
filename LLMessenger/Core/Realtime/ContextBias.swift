// LLMessenger/Core/Realtime/ContextBias.swift
import Foundation

/// Result of a triage decision. Shared between TriageEngine and ContextBias.
struct TriageResult {
    let priority: String
    let needsReply: Bool
    let reason: String
}

/// Deterministic, additive biasing of a triage decision using a conversation's
/// ConversationContext. Softer than rules: key senders short-circuit, topic
/// matches nudge priority up or down. A nil/empty context leaves the decision
/// untouched so pre-P2 behavior is preserved.
enum ContextBias {

    /// Returns the matching key sender if the newest message's sender is listed
    /// in keySendersList (case-insensitive substring), else nil.
    static func matchingKeySender(sender: String, context: ConversationContext) -> String? {
        context.keySendersList.first { key in
            !key.isEmpty && sender.localizedCaseInsensitiveContains(key)
        }
    }

    /// Applies topic biasing to an LLM result. Important topic → raise; noise
    /// topic (and not important) → lower. No matches → unchanged.
    static func applyTopicBias(
        to result: TriageResult,
        newestText: String,
        context: ConversationContext?
    ) -> TriageResult {
        guard let context else { return result }

        let hasImportant = context.importantTopicsList.contains { topic in
            !topic.isEmpty && newestText.localizedCaseInsensitiveContains(topic)
        }
        let hasNoise = context.noiseTopicsList.contains { topic in
            !topic.isEmpty && newestText.localizedCaseInsensitiveContains(topic)
        }

        if hasImportant {
            let raised = raise(result.priority)
            guard raised != result.priority else { return result }
            return TriageResult(
                priority: raised,
                needsReply: raised == "high" ? true : result.needsReply,
                reason: "Important topic — \(result.reason)"
            )
        }

        if hasNoise {
            let lowered = lower(result.priority)
            guard lowered != result.priority else { return result }
            return TriageResult(
                priority: lowered,
                needsReply: result.needsReply,
                reason: "Noise topic — \(result.reason)"
            )
        }

        return result
    }

    /// Compact context block injected into the LLM prompt so the model is informed.
    /// Empty string when the context carries no relevant fields.
    static func promptBlock(for context: ConversationContext) -> String {
        var lines: [String] = []
        if let note = context.contextNote, !note.isEmpty {
            lines.append("Note: \(sanitize(note))")
        }
        let important = context.importantTopicsList
        if !important.isEmpty {
            lines.append("Important topics: \(important.map(sanitize).joined(separator: ", "))")
        }
        let noise = context.noiseTopicsList
        if !noise.isEmpty {
            lines.append("Noise topics (deprioritize): \(noise.map(sanitize).joined(separator: ", "))")
        }
        guard !lines.isEmpty else { return "" }
        return "\nConversation context (honor this):\n" + lines.joined(separator: "\n") + "\n"
    }

    private static func raise(_ priority: String) -> String {
        switch priority {
        case "low":             return "medium"
        case "med", "medium":   return "high"
        default:                return "high"
        }
    }

    private static func lower(_ priority: String) -> String {
        switch priority {
        case "high":            return "medium"
        case "med", "medium":   return "low"
        default:                return "low"
        }
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }
}
