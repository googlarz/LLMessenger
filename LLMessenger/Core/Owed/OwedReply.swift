// LLMessenger/Core/Owed/OwedReply.swift
//
// A derived "you owe a reply" item. Not a table — recomputed from messages,
// triage events, and conversation context each time the Owed surface loads.

import Foundation

struct OwedReply: Identifiable, Equatable {
    var id: String { "\(service)|\(conversationId)|\(triggerMessageId)" }
    let service: String
    let conversationId: String
    let conversationName: String
    let triggerMessageId: String
    let triggerText: String
    let triggeredAt: Date
    let reason: String          // "needs reply" | "unanswered question"
    let priorityRank: Int       // higher = more important (from context priorityHint)

    func ageDays(now: Date) -> Int {
        let seconds = now.timeIntervalSince(triggeredAt)
        return max(0, Int(seconds / 86400))
    }
}
