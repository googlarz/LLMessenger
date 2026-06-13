// LLMessenger/Core/Realtime/TriageEngine.swift
import Foundation
import GRDB

actor TriageEngine {
    private let db: AppDatabase
    private let llmClient: any LLMClient
    private let notificationManager: NotificationManager

    init(db: AppDatabase, llmClient: any LLMClient, notificationManager: NotificationManager) {
        self.db = db
        self.llmClient = llmClient
        self.notificationManager = notificationManager
    }

    func triage(
        service: String,
        conversationId: String,
        conversationName: String,
        messages: [Message],
        rules: [PriorityRule]
    ) async throws {
        guard let newest = messages.max(by: { $0.timestamp < $1.timestamp }) else { return }

        if let match = RuleEvaluator.evaluate(
            contactName: conversationName,
            service: service,
            messageText: newest.text,
            rules: rules
        ) {
            switch match.action {
            case .alwaysNotify:
                let pattern = match.rule.contactPattern ?? match.rule.keywordPattern ?? ""
                var event = TriageEvent(
                    id: nil,
                    service: service,
                    conversationId: conversationId,
                    priority: "high",
                    needsReply: true,
                    reason: "Rule: \(pattern)",
                    triggeredBy: "rule",
                    notified: true,
                    createdAt: Date()
                )
                try await db.dbQueue.write { db in try event.insert(db) }
                await fireNotification(title: conversationName, body: "Rule: \(pattern)")
                return

            case .suppress:
                var event = TriageEvent(
                    id: nil,
                    service: service,
                    conversationId: conversationId,
                    priority: "low",
                    needsReply: false,
                    reason: "Suppressed by rule",
                    triggeredBy: "rule",
                    notified: false,
                    createdAt: Date()
                )
                try await db.dbQueue.write { db in try event.insert(db) }
                return

            case .setPriority:
                // Fall through to LLM triage — setPriority is a hint, not a firewall action.
                break
            }
        }

        // LLM path
        let last5 = messages.sorted { $0.timestamp < $1.timestamp }.suffix(5)
        let msgLines = last5.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
        let prompt = """
You are a message triage assistant. Analyze these messages and respond with JSON only: \
{"priority":"high"|"medium"|"low","needsReply":true|false,"reason":"one sentence"}

Conversation:
\(msgLines)
"""

        do {
            let response = try await llmClient.complete(
                model: "gpt-4o-mini",
                messages: [LLMMessage(role: .user, content: prompt)],
                maxTokens: 200
            )
            let parsed = try parseTriageJSON(response.text)
            var event = TriageEvent(
                id: nil,
                service: service,
                conversationId: conversationId,
                priority: parsed.priority,
                needsReply: parsed.needsReply,
                reason: parsed.reason,
                triggeredBy: "llm",
                notified: parsed.needsReply,
                createdAt: Date()
            )
            try await db.dbQueue.write { db in try event.insert(db) }
            if parsed.needsReply {
                await fireNotification(title: conversationName, body: parsed.reason)
            }
        } catch {
            var event = TriageEvent(
                id: nil,
                service: service,
                conversationId: conversationId,
                priority: "medium",
                needsReply: false,
                reason: "Triage unavailable",
                triggeredBy: "fallback",
                notified: false,
                createdAt: Date()
            )
            try await db.dbQueue.write { db in try event.insert(db) }
        }
    }

    private struct TriageResult {
        let priority: String
        let needsReply: Bool
        let reason: String
    }

    private func parseTriageJSON(_ text: String) throws -> TriageResult {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let priority = json["priority"] as? String,
              let needsReply = json["needsReply"] as? Bool,
              let reason = json["reason"] as? String
        else { throw LLMError.invalidResponse }
        let validPriority = ["high", "medium", "low"].contains(priority) ? priority : "medium"
        return TriageResult(priority: validPriority, needsReply: needsReply, reason: reason)
    }

    @MainActor
    private func fireNotification(title: String, body: String) {
        notificationManager.post(briefID: Int64(Date().timeIntervalSince1970), title: title, body: body)
    }
}
