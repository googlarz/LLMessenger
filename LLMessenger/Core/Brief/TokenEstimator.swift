// LLMessenger/Core/Brief/TokenEstimator.swift
//
// LLMs have no visibility here today: BriefEngine caps context by raw message
// COUNT (30 conversations × last 100 messages), not by size. 100 one-line "ok"
// messages and 100 paragraph-length messages get identical treatment — the
// short case wastes budget headroom, the long case can still blow past what a
// small local model's context window holds, with the overflow either silently
// truncated by the backend or (worse) pushing genuinely relevant content out
// with no signal to the user. This estimator lets truncation adapt to actual
// content size instead of a blind row count.

import Foundation

enum TokenEstimator {
    /// Rough chars-per-token ratio for English-like text. Deliberately simple —
    /// this is a budget guardrail, not a tokenizer; being off by 20-30% doesn't
    /// matter when the alternative is no accounting at all.
    private static let charsPerToken: Double = 4.0

    static func estimate(_ text: String) -> Int {
        max(1, Int(Double(text.count) / charsPerToken))
    }

    static func estimate(_ texts: some Sequence<String>) -> Int {
        texts.reduce(0) { $0 + estimate($1) }
    }

    static func truncated(_ text: String, toTokenBudget tokenBudget: Int) -> String {
        guard estimate(text) > tokenBudget else { return text }
        let marker = "\n[Message truncated to fit prompt]"
        let characterBudget = max(0, Int(Double(max(1, tokenBudget)) * charsPerToken) - marker.count)
        return String(text.prefix(characterBudget)) + marker
    }

    /// Selects the most recent messages from a chronologically-sorted (oldest
    /// first) array that fit within `tokenBudget`, walking backward from the
    /// newest. Replaces a blind `.suffix(n)` row-count cap: a thread of short
    /// messages keeps more history, a thread of long messages keeps less,
    /// instead of both getting an identical 100-message window regardless of
    /// how much content that actually is. `hardCountCeiling` remains as a
    /// backstop against pathological cases (thousands of one-word messages)
    /// where the budget alone wouldn't bound prompt-construction cost.
    /// Generic over both `Message` (the DB model) and `AdapterMessage` (the
    /// live-fetch model) — both carry a `.text` field, nothing else is needed.
    static func selectWithinBudget<M>(
        _ messages: [M],
        tokenBudget: Int,
        hardCountCeiling: Int = 300,
        text: (M) -> String
    ) -> [M] {
        guard !messages.isEmpty else { return [] }
        var selected: [M] = []
        var used = 0
        for message in messages.reversed() {
            guard selected.count < hardCountCeiling else { break }
            let cost = estimate(text(message))
            guard used + cost <= tokenBudget || selected.isEmpty else { break }
            selected.append(message)
            used += cost
        }
        return selected.reversed()
    }
}
