// LLMessenger/Core/Realtime/TriageEngine.swift
import Foundation
import GRDB

actor TriageEngine {
    private let db: AppDatabase
    private let llmClient: any LLMClient
    private let llmModel: String
    private let notificationManager: NotificationManager
    private var inFlightMessageKeys: Set<String> = []

    init(
        db: AppDatabase,
        llmClient: any LLMClient,
        llmModel: String,
        notificationManager: NotificationManager
    ) {
        self.db = db
        self.llmClient = llmClient
        self.llmModel = llmModel
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
        let messageKey = "\(service)\u{1F}\(newest.messageId)"
        guard inFlightMessageKeys.insert(messageKey).inserted else { return }
        defer { inFlightMessageKeys.remove(messageKey) }

        let alreadyTriaged = try await db.dbQueue.read { database in
            try TriageEvent
                .filter(Column("service") == service)
                .filter(Column("messageId") == newest.messageId)
                .fetchCount(database) > 0
        }
        guard !alreadyTriaged else { return }

        // Privacy is loaded before any path can reach the LLM. Deterministic
        // local rules may still notify, but never_draft always blocks inference.
        let context = try? await db.dbQueue.read { database in
            try ConversationContext.fetchOne(
                database,
                key: ["service": service, "conversationId": conversationId]
            )
        }

        if let match = RuleEvaluator.evaluate(
            contactName: conversationName,
            service: service,
            messageText: newest.text,
            rules: rules
        ) {
            switch match.action {
            case .alwaysNotify:
                let pattern = match.rule.contactPattern ?? match.rule.keywordPattern ?? ""
                let event = TriageEvent(
                    id: nil,
                    service: service,
                    conversationId: conversationId,
                    messageId: newest.messageId,
                    priority: "high",
                    needsReply: true,
                    reason: "Rule: \(pattern)",
                    triggeredBy: "rule",
                    notified: true,
                    createdAt: Date()
                )
                if try await persistIfNew(event) {
                    await fireNotification(title: conversationName, body: "Rule: \(pattern)")
                }
                return

            case .suppress:
                let event = TriageEvent(
                    id: nil,
                    service: service,
                    conversationId: conversationId,
                    messageId: newest.messageId,
                    priority: "low",
                    needsReply: false,
                    reason: "Suppressed by rule",
                    triggeredBy: "rule",
                    notified: false,
                    createdAt: Date()
                )
                _ = try await persistIfNew(event)
                return

            case .setPriority:
                // Fall through to LLM triage — setPriority is a hint, not a firewall action.
                break
            }
        }

        let inferenceBlocked = context?.privacyOverride == "never_draft"
            || (context?.privacyOverride == "local_only" && llmClient.isCloud)
        if inferenceBlocked {
            let heldLocal = context?.privacyOverride == "local_only"
            let event = TriageEvent(
                id: nil,
                service: service,
                conversationId: conversationId,
                messageId: newest.messageId,
                priority: "medium",
                needsReply: false,
                reason: heldLocal
                    ? "Held local — cloud triage disabled for this conversation"
                    : "Private conversation — automatic triage disabled",
                triggeredBy: "privacy",
                notified: false,
                createdAt: Date()
            )
            _ = try await persistIfNew(event)
            return
        }

        // Strong context signal: newest sender is a key sender → short-circuit before the LLM.
        if let context,
           let keySender = ContextBias.matchingKeySender(sender: newest.sender, context: context) {
            let event = TriageEvent(
                id: nil,
                service: service,
                conversationId: conversationId,
                messageId: newest.messageId,
                priority: "high",
                needsReply: true,
                reason: "Key sender: \(keySender)",
                triggeredBy: "context",
                notified: true,
                createdAt: Date()
            )
            if try await persistIfNew(event) {
                await fireNotification(title: conversationName, body: "Key sender: \(keySender)")
            }
            return
        }

        // LLM path
        let last5 = messages.sorted { $0.timestamp < $1.timestamp }.suffix(5)
        let msgLines = last5.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
        let contextBlock = context.map { ContextBias.promptBlock(for: $0) } ?? ""
        let prompt = """
You are a message triage assistant. Analyze these messages and respond with JSON only: \
{"priority":"high"|"medium"|"low","needsReply":true|false,"reason":"one sentence"}
\(contextBlock)
Conversation:
\(msgLines)
"""

        do {
            let response = try await llmClient.complete(
                model: llmModel,
                messages: [LLMMessage(role: .user, content: prompt)],
                maxTokens: 200
            )
            let parsed = try parseTriageJSON(response.text)
            let biased = ContextBias.applyTopicBias(to: parsed, newestText: newest.text, context: context)
            let event = TriageEvent(
                id: nil,
                service: service,
                conversationId: conversationId,
                messageId: newest.messageId,
                priority: biased.priority,
                needsReply: biased.needsReply,
                reason: biased.reason,
                triggeredBy: biased.priority == parsed.priority ? "llm" : "context",
                notified: biased.needsReply,
                createdAt: Date()
            )
            if try await persistIfNew(event), biased.needsReply {
                await fireNotification(title: conversationName, body: biased.reason)
            }
        } catch {
            let event = TriageEvent(
                id: nil,
                service: service,
                conversationId: conversationId,
                messageId: newest.messageId,
                priority: "medium",
                needsReply: false,
                reason: "Triage unavailable",
                triggeredBy: "fallback",
                notified: false,
                createdAt: Date()
            )
            _ = try await persistIfNew(event)
        }
    }

    private func persistIfNew(_ event: TriageEvent) async throws -> Bool {
        try await db.dbQueue.write { database in
            let event = event
            try event.insert(database, onConflict: .ignore)
            return database.changesCount > 0
        }
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
