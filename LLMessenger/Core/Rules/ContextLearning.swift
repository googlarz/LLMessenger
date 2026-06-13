// LLMessenger/Core/Rules/ContextLearning.swift
import Foundation

/// Nudges a conversation's ConversationContext when the user corrects a card's priority
/// downward, so future triage reflects the learned preference. Called right after the
/// PriorityCorrection itself is persisted — it never replaces that behavior.
enum ContextLearning {
    private static let priorityRank: [String: Int] = ["high": 3, "med": 2, "medium": 2, "low": 1]

    static func applyCorrection(
        db: BriefRepository,
        service: String,
        conversationId: String,
        from llmPriority: String,
        to userPriority: String,
        cardHeadline: String
    ) {
        let fromRank = priorityRank[llmPriority.lowercased()] ?? 2
        let toRank = priorityRank[userPriority.lowercased()] ?? 2
        // Only learn from downgrades ("this didn't need me").
        guard toRank < fromRank else { return }

        let existing = try? db.fetchConversationContext(service: service, conversationId: conversationId)
        var ctx = existing ?? ConversationContext(
            service: service,
            conversationId: conversationId,
            label: "",
            priorityHint: "auto",
            updatedAt: Date()
        )

        // Add the headline as a noise topic (first meaningful keyword), capped to avoid unbounded growth.
        if let keyword = noiseKeyword(from: cardHeadline) {
            var noise = ctx.noiseTopicsList
            if !noise.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) {
                noise.append(keyword)
                ctx.noiseTopicsList = Array(noise.suffix(20))
            }
        }

        // Nudge the explicit priority hint down a notch when it isn't already low.
        if ctx.priorityHint == "high" {
            ctx.priorityHint = "med"
        } else if ctx.priorityHint == "med" || ctx.priorityHint == "medium" || ctx.priorityHint == "auto" {
            ctx.priorityHint = "low"
        }

        ctx.updatedAt = Date()
        try? db.upsertConversationContext(ctx)
    }

    private static func noiseKeyword(from headline: String) -> String? {
        let trimmed = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }
}
