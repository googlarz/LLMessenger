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
