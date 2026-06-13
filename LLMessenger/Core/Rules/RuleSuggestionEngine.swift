// LLMessenger/Core/Rules/RuleSuggestionEngine.swift
import Foundation
import GRDB

struct RuleSuggestion: Identifiable {
    let id: UUID
    let contactName: String
    let service: String
    let evidenceCount: Int
    var dismissed: Bool
}

struct ContextSuggestion: Identifiable {
    let id: String              // "service|conversationId|kind"
    let service: String
    let conversationId: String
    let conversationName: String
    let kind: String            // "keySender" | "prioritize"
    let subject: String         // e.g. the sender name
    let rationale: String       // human sentence
}

actor RuleSuggestionEngine {
    private static let defaultsKey = "dismissedRuleSuggestions"
    private static let fastReplyThreshold: TimeInterval = 5 * 60   // 5 minutes
    private static let minConversations = 5

    func computeSuggestions(db: AppDatabase) async throws -> [RuleSuggestion] {
        // Fetch all sent messages joined with the preceding received message in
        // the same conversation so we can compute reply latency.
        let rows = try await db.dbQueue.read { grdb -> [(service: String, convId: String, convName: String?, sent: Date, prevReceived: Date?)] in
            // Fetch sent messages
            let sent = try Row.fetchAll(grdb, sql: """
                SELECT service, conversationId, conversationName, timestamp
                FROM messages
                WHERE isSent = 1
                ORDER BY timestamp ASC
            """)
            // Fetch received messages
            let received = try Row.fetchAll(grdb, sql: """
                SELECT service, conversationId, timestamp
                FROM messages
                WHERE isSent = 0
                ORDER BY timestamp ASC
            """)

            // Build lookup: last received timestamp per (service, conversationId) before a given sent time
            // Group received by (service, conversationId)
            var receivedByConv: [String: [Date]] = [:]
            for row in received {
                let key = "\(row["service"] as! String)|\(row["conversationId"] as! String)"
                let ts = row["timestamp"] as! Date
                receivedByConv[key, default: []].append(ts)
            }

            return sent.map { row in
                let service = row["service"] as! String
                let convId = row["conversationId"] as! String
                let convName = row["conversationName"] as? String
                let sentTime = row["timestamp"] as! Date
                let key = "\(service)|\(convId)"
                let prevReceived = receivedByConv[key]?
                    .filter { $0 < sentTime }
                    .max()
                return (service: service, convId: convId, convName: convName, sent: sentTime, prevReceived: prevReceived)
            }
        }

        // Group by (service, convName/convId) and count fast replies
        var fastReplyCounts: [String: (service: String, name: String, count: Int)] = [:]
        for row in rows {
            guard let prev = row.prevReceived else { continue }
            let latency = row.sent.timeIntervalSince(prev)
            guard latency >= 0, latency < Self.fastReplyThreshold else { continue }
            let contactName = row.convName ?? row.convId
            let key = "\(row.service)|\(contactName)"
            if var existing = fastReplyCounts[key] {
                existing.count += 1
                fastReplyCounts[key] = existing
            } else {
                fastReplyCounts[key] = (service: row.service, name: contactName, count: 1)
            }
        }

        let dismissed = Self.loadDismissed()
        return fastReplyCounts.values
            .filter { $0.count >= Self.minConversations }
            .map { entry in
                RuleSuggestion(
                    id: UUID(),
                    contactName: entry.name,
                    service: entry.service,
                    evidenceCount: entry.count,
                    dismissed: dismissed.contains("\(entry.service)|\(entry.name)")
                )
            }
            .sorted { $0.evidenceCount > $1.evidenceCount }
    }

    // MARK: - Context suggestions

    private static let contextDefaultsKey = "dismissedContextSuggestions"
    private static let dailyBudget = 3

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// From backfilled history, detect a sender the user replies to fast (<5 min) across
    /// ≥5 instances, OR a clearly-dominant sender in a group → suggest a keySender / prioritize
    /// context. Capped by the remaining per-day budget. `now` is injectable for tests.
    func computeContextSuggestions(db: AppDatabase, now: Date = Date()) async throws -> [ContextSuggestion] {
        let remaining = Self.remainingBudget(now: now)
        guard remaining > 0 else { return [] }

        // (service, conversationId, sender) → (conversationName, fast-reply count, total received from sender)
        struct Stat { var convName: String; var fastReplies: Int; var received: Int }

        let stats = try await db.dbQueue.read { grdb -> [String: Stat] in
            let received = try Row.fetchAll(grdb, sql: """
                SELECT service, conversationId, conversationName, sender, timestamp
                FROM messages
                WHERE isSent = 0
                ORDER BY timestamp ASC
            """)
            let sent = try Row.fetchAll(grdb, sql: """
                SELECT service, conversationId, timestamp
                FROM messages
                WHERE isSent = 1
                ORDER BY timestamp ASC
            """)

            // Sent timestamps grouped per conversation, for fast-reply lookup.
            var sentByConv: [String: [Date]] = [:]
            for row in sent {
                let key = "\(row["service"] as String)|\(row["conversationId"] as String)"
                let ts: Date = row["timestamp"]
                sentByConv[key, default: []].append(ts)
            }

            var out: [String: Stat] = [:]
            for row in received {
                let service: String = row["service"]
                let convId: String = row["conversationId"]
                let convName = (row["conversationName"] as String?) ?? convId
                let sender: String = row["sender"]
                let ts: Date = row["timestamp"]
                let statKey = "\(service)|\(convId)|\(sender)"

                let convKey = "\(service)|\(convId)"
                let repliedFast = sentByConv[convKey]?.contains { reply in
                    let dt = reply.timeIntervalSince(ts)
                    return dt >= 0 && dt < Self.fastReplyThreshold
                } ?? false

                var s = out[statKey] ?? Stat(convName: convName, fastReplies: 0, received: 0)
                s.convName = convName
                s.received += 1
                if repliedFast { s.fastReplies += 1 }
                out[statKey] = s
            }
            return out
        }

        let dismissed = Self.loadDismissedContext()
        var suggestions: [ContextSuggestion] = []
        for (key, stat) in stats {
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let service = parts[0], convId = parts[1], sender = parts[2]
            guard stat.fastReplies >= Self.minConversations else { continue }
            let id = "\(service)|\(convId)|keySender"
            guard !dismissed.contains(id) else { continue }
            suggestions.append(ContextSuggestion(
                id: id,
                service: service,
                conversationId: convId,
                conversationName: stat.convName,
                kind: "keySender",
                subject: sender,
                rationale: "You reply to \(sender) within minutes — \(stat.fastReplies) times. Mark them a key sender?"
            ))
        }

        suggestions.sort { $0.subject < $1.subject }
        let capped = Array(suggestions.prefix(remaining))
        if !capped.isEmpty {
            Self.recordShown(capped.count, now: now)
        }
        return capped
    }

    func dismissContext(suggestion: ContextSuggestion) {
        var set = Self.loadDismissedContext()
        set.insert(suggestion.id)
        UserDefaults.standard.set(Array(set), forKey: Self.contextDefaultsKey)
    }

    private static func loadDismissedContext() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: contextDefaultsKey) ?? [])
    }

    private static func budgetKey(now: Date) -> String {
        "contextSuggestionsShown_\(dayFormatter.string(from: now))"
    }

    private static func remainingBudget(now: Date) -> Int {
        let shown = UserDefaults.standard.integer(forKey: budgetKey(now: now))
        return max(0, dailyBudget - shown)
    }

    private static func recordShown(_ count: Int, now: Date) {
        let key = budgetKey(now: now)
        let shown = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(shown + count, forKey: key)
    }

    func dismiss(suggestion: RuleSuggestion) {
        var set = Self.loadDismissed()
        set.insert("\(suggestion.service)|\(suggestion.contactName)")
        UserDefaults.standard.set(Array(set), forKey: Self.defaultsKey)
    }

    private static func loadDismissed() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return Set(arr)
    }
}
