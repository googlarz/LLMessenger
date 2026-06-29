// LLMessenger/Core/Owed/OwedReplyDeriver.swift
//
// Derives the set of conversations where the latest inbound message is still
// unanswered and warrants a reply. Balanced: a thread is "owed" only if it was
// flagged by triage OR the latest inbound message is question-shaped.

import Foundation
import GRDB

/// UserDefaults-backed dismiss/snooze state for owed replies. Mirrors
/// RuleSuggestionEngine's dismissal pattern (Array<String> under a defaults key).
enum OwedReplyStore {
    static let dismissedKey = "dismissedOwedReplies"
    static let snoozedKey = "snoozedOwedReplies"

    static func dismissedIDs(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: dismissedKey) ?? [])
    }

    static func dismiss(_ id: String, defaults: UserDefaults = .standard) {
        var set = dismissedIDs(defaults)
        set.insert(id)
        defaults.set(Array(set), forKey: dismissedKey)
    }

    /// Map of id → ISO8601 snooze-until string.
    static func snoozedMap(_ defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: snoozedKey) as? [String: String] ?? [:]
    }

    static func snooze(_ id: String, until date: Date, defaults: UserDefaults = .standard) {
        var map = snoozedMap(defaults)
        map[id] = ISO8601DateFormatter().string(from: date)
        defaults.set(map, forKey: snoozedKey)
    }

    /// Returns ids whose snooze date is still in the future relative to `now`.
    static func activeSnoozedIDs(now: Date, defaults: UserDefaults = .standard) -> Set<String> {
        let formatter = ISO8601DateFormatter()
        var active: Set<String> = []
        for (id, iso) in snoozedMap(defaults) {
            if let until = formatter.date(from: iso), until > now {
                active.insert(id)
            }
        }
        return active
    }
}

struct OwedReplyDeriver {
    private static let maxMessagesPerRun = 3_000

    private static let interrogativeOpeners: Set<String> = [
        "who", "what", "when", "where", "why", "how",
        "can", "could", "would", "will", "are", "is", "do", "did", "should"
    ]

    func derive(db: AppDatabase,
                contexts: [ConversationContext],
                horizonDays: Int = 14,
                now: Date = Date()) throws -> [OwedReply] {
        let cutoff = now.addingTimeInterval(-Double(horizonDays) * 86400)

        let messages: [Message] = try db.dbQueue.read { grdb in
            try Message
                .filter(Column("timestamp") >= cutoff)
                .order(Column("timestamp").asc)
                .limit(Self.maxMessagesPerRun)
                .fetchAll(grdb)
        }

        // Group by conversation.
        var byConversation: [String: [Message]] = [:]
        for msg in messages {
            byConversation["\(msg.service)|\(msg.conversationId)", default: []].append(msg)
        }

        // Triage flags: (service, conversationId) → latest needsReply createdAt.
        let triageFlags: [String: Date] = try db.dbQueue.read { grdb in
            let rows = try Row.fetchAll(grdb, sql: """
                SELECT service, conversationId, MAX(createdAt) AS latest
                FROM triageEvents
                WHERE needsReply = 1
                GROUP BY service, conversationId
            """)
            var map: [String: Date] = [:]
            for row in rows {
                guard let service = row["service"] as String?,
                      let convId = row["conversationId"] as String?,
                      let latest = row["latest"] as Date? else { continue }
                map["\(service)|\(convId)"] = latest
            }
            return map
        }

        let contextByKey = Dictionary(
            contexts.map { ("\($0.service)|\($0.conversationId)", $0) },
            uniquingKeysWith: { a, _ in a }
        )

        let dismissed = OwedReplyStore.dismissedIDs()
        let snoozed = OwedReplyStore.activeSnoozedIDs(now: now)

        var owed: [OwedReply] = []
        for (key, convMessages) in byConversation {
            guard let latestInbound = convMessages.last(where: { !$0.isSent }) else { continue }

            // Cleared if the user sent anything after the latest inbound message.
            let repliedAfter = convMessages.contains { $0.isSent && $0.timestamp > latestInbound.timestamp }
            if repliedAfter { continue }

            // Include only if flagged by triage at/after the inbound, or question-shaped.
            let flaggedAt = triageFlags[key]
            let triageFlagged = flaggedAt.map { $0 >= latestInbound.timestamp.addingTimeInterval(-1) } ?? false
            let questionShaped = Self.isQuestionShaped(latestInbound.text)
            guard triageFlagged || questionShaped else { continue }

            let reason = triageFlagged ? "needs reply" : "unanswered question"
            let rank = Self.priorityRank(contextByKey[key]?.priorityHint)

            let entry = OwedReply(
                service: latestInbound.service,
                conversationId: latestInbound.conversationId,
                conversationName: latestInbound.conversationName ?? latestInbound.conversationId,
                triggerMessageId: latestInbound.messageId,
                triggerText: latestInbound.text,
                triggeredAt: latestInbound.timestamp,
                reason: reason,
                priorityRank: rank
            )

            if dismissed.contains(entry.id) || snoozed.contains(entry.id) { continue }
            owed.append(entry)
        }

        return owed.sorted { lhs, rhs in
            if lhs.priorityRank != rhs.priorityRank { return lhs.priorityRank > rhs.priorityRank }
            return lhs.triggeredAt < rhs.triggeredAt   // older first within a rank
        }
    }

    static func priorityRank(_ hint: String?) -> Int {
        switch hint {
        case "high": return 3
        case "med":  return 1
        case "low":  return 0
        default:     return 2   // "auto" or nil
        }
    }

    static func isQuestionShaped(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        let firstWord = trimmed
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first { !$0.isEmpty } ?? ""
        return interrogativeOpeners.contains(firstWord)
    }
}
