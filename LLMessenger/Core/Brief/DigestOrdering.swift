// LLMessenger/Core/Brief/DigestOrdering.swift
import Foundation

/// Pure ordering/collapsing for the morning digest.
/// Sorts cards by per-conversation context priorityHint (high first), falling back to
/// the card's own LLM priority, then preserving the original order. Cards whose context
/// marks them "low" priority — or whose content is dominated by the context's noiseTopics —
/// are flagged `collapsed` so the digest can render them as a single compact line.
enum DigestOrdering {

    struct Ordered {
        let card: BriefCard
        let collapsed: Bool
    }

    static func order(cards: [BriefCard], contexts: [ConversationContext]) -> [Ordered] {
        let contextByKey: [String: ConversationContext] = Dictionary(
            contexts.map { ("\($0.service)|\($0.conversationId)", $0) },
            uniquingKeysWith: { a, _ in a }
        )

        func context(for card: BriefCard) -> ConversationContext? {
            contextByKey["\(card.service)|\(card.conversationId)"]
        }

        func rank(_ card: BriefCard) -> Int {
            let hint = context(for: card)?.priorityHint ?? "auto"
            let priority = hint == "auto" ? card.priority : hint
            switch priority {
            case "high": return 0
            case "med", "medium": return 1
            case "low": return 3
            default: return 2  // auto/unknown
            }
        }

        func isNoiseDominated(_ card: BriefCard) -> Bool {
            guard let ctx = context(for: card) else { return false }
            let noise = ctx.noiseTopicsList
            guard !noise.isEmpty else { return false }
            let haystack = "\(card.headline) \(card.summary)".lowercased()
            return noise.contains { haystack.contains($0.lowercased()) }
        }

        func collapsed(_ card: BriefCard) -> Bool {
            (context(for: card)?.priorityHint == "low") || isNoiseDominated(card)
        }

        return cards.enumerated()
            .sorted { lhs, rhs in
                let lr = rank(lhs.element), rr = rank(rhs.element)
                if lr != rr { return lr < rr }
                return lhs.offset < rhs.offset
            }
            .map { Ordered(card: $0.element, collapsed: collapsed($0.element)) }
    }
}
