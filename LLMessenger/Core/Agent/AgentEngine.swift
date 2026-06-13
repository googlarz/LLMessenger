// LLMessenger/Core/Agent/AgentEngine.swift
//
// The agent's planning loop. Mirrors RealtimeMonitor's actor + tick pattern.
// Each cycle it gathers the conversations where the user owes a reply, drafts a
// reply in the user's per-conversation voice (validated-JSON LLM output, same
// manual pattern as BriefEngine), and persists each as a PENDING AgentAction.
//
// P1 has NO auto-send. A proposed action is just a suggestion; the user approves
// it from the Act surface, and approval routes through the existing confirmed-send
// path. The engine proposes; it never sends.

import Foundation
import GRDB

actor AgentEngine {
    private let db: AppDatabase
    private let llmClient: any LLMClient
    private let llmModel: String
    private let repository: BriefRepository
    private let rulesProvider: @Sendable () async -> [PriorityRule]

    private var running = false
    private var tickTask: Task<Void, Never>?

    var isRunning: Bool { running }

    var onActionsChanged: (@Sendable () async -> Void)?

    init(db: AppDatabase,
         llmClient: any LLMClient,
         llmModel: String,
         repository: BriefRepository,
         rulesProvider: @escaping @Sendable () async -> [PriorityRule]) {
        self.db = db
        self.llmClient = llmClient
        self.llmModel = llmModel
        self.repository = repository
        self.rulesProvider = rulesProvider
    }

    func setOnActionsChanged(_ callback: @escaping @Sendable () async -> Void) {
        self.onActionsChanged = callback
    }

    func start() async {
        guard !running else { return }
        running = true
        tickTask = Task { [weak self] in
            while true {
                guard let self, await self.isRunning else { return }
                await self.trigger()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() async {
        running = false
        tickTask?.cancel()
        tickTask = nil
    }

    /// Run one planning cycle now. Honors the kill switch.
    func trigger() async {
        guard !UserDefaults.standard.bool(forKey: "agentDisabled") else { return }

        let owed: [OwedReply]
        do {
            let contexts = try repository.fetchAllConversationContexts()
            owed = try OwedReplyDeriver().derive(db: db, contexts: contexts)
        } catch {
            return
        }

        let existingPending = (try? pendingActionKeys()) ?? []
        var produced = false

        for reply in owed {
            let key = "\(reply.service)|\(reply.conversationId)"
            // Dedupe: one pending reply per conversation.
            if existingPending.contains(key) { continue }

            if let action = await proposeReply(for: reply) {
                do {
                    try persist(action)
                    produced = true
                } catch {
                    continue
                }
            }
        }

        if produced { await onActionsChanged?() }
    }

    // MARK: - Reply proposal

    private func proposeReply(for reply: OwedReply) async -> AgentAction? {
        let ctx = (try? repository.fetchConversationContext(
            service: reply.service, conversationId: reply.conversationId)) ?? nil

        // Privacy: never_draft → no reply action at all.
        if ctx?.privacyOverride == "never_draft" { return nil }
        // Privacy: local_only → only draft with a local model.
        if ctx?.privacyOverride == "local_only", !llmClient.isLocal { return nil }

        // Sample the user's voice the same way ChatViewModel does.
        let styleSince = Date().addingTimeInterval(-ReplyVoiceSampler.styleWindowDays * 24 * 3600)
        let recentAll = (try? repository.fetchMessages(service: reply.service, since: styleSince)) ?? []
        let sentTexts = ReplyVoiceSampler.sampleSentTexts(
            messages: recentAll, conversationId: reply.conversationId)
        let styleBlock = ReplyVoiceSampler.styleBlock(sentTexts: sentTexts, tone: ctx?.tone)

        let userContent = """
        You are drafting a reply on the user's behalf to the most recent unanswered message.

        Conversation: \(reply.conversationName) (\(Theme.serviceName(reply.service)))
        Latest message you must answer:
        \(reply.triggerText)

        \(styleBlock.isEmpty ? "(no voice sample — use a neutral, casual register)" : styleBlock)

        Respond with ONLY a JSON object (no markdown fences) with exactly these keys:
        {"title": "<short label, max 8 words>", "draftText": "<the reply text, in the user's voice>", "reasoning": "<one sentence why this reply>", "confidence": <0.0-1.0>}
        """

        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: "You draft message replies in the user's voice. Output only valid JSON."),
            LLMMessage(role: .user, content: userContent)
        ]

        let response: LLMResponse
        do {
            response = try await llmClient.complete(model: llmModel, messages: messages, maxTokens: 400)
        } catch {
            return nil
        }

        guard let draft = decodeAndValidateDraft(response.text) else { return nil }

        let risk = Self.riskLevel(draftText: draft.draftText,
                                  triggerText: reply.triggerText,
                                  hasSentHistory: !sentTexts.isEmpty)

        return AgentAction(
            id: nil,
            kind: AgentActionKind.reply.rawValue,
            service: reply.service,
            conversationId: reply.conversationId,
            conversationName: reply.conversationName,
            title: draft.title,
            payload: AgentAction.encodeReplyPayload(draft.draftText),
            reasoning: draft.reasoning,
            confidence: draft.confidence,
            riskLevel: risk.rawValue,
            status: AgentActionStatus.pending.rawValue,
            createdAt: Date(),
            resolvedAt: nil
        )
    }

    // MARK: - Validated JSON decode (manual pattern, mirrors BriefEngine)

    private struct DraftJSON: Codable {
        let title: String
        let draftText: String
        let reasoning: String
        let confidence: Double
    }

    private func decodeAndValidateDraft(_ text: String) -> DraftJSON? {
        let clean = stripMarkdownFences(text)
        guard let data = clean.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(DraftJSON.self, from: data) else { return nil }
        let draft = parsed.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return nil }
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return DraftJSON(
            title: title.isEmpty ? "Reply" : title,
            draftText: draft,
            reasoning: parsed.reasoning,
            confidence: min(max(parsed.confidence, 0), 1)
        )
    }

    private func stripMarkdownFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        return trimmed
            .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Risk heuristics

    static func riskLevel(draftText: String, triggerText: String, hasSentHistory: Bool) -> AgentActionRisk {
        let combined = (draftText + " " + triggerText).lowercased()
        let containsLink = combined.contains("http://") || combined.contains("https://") || combined.contains("www.")
        let moneyTerms = ["$", "€", "£", "pay", "invoice", "venmo", "paypal", "transfer", "refund", "wire"]
        let containsMoney = moneyTerms.contains { combined.contains($0) }
        // New recipient: no prior sent history in this conversation.
        let newRecipient = !hasSentHistory

        if containsLink || containsMoney || newRecipient { return .high }

        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 25 { return .low }
        return .normal
    }

    // MARK: - Persistence

    private func pendingActionKeys() throws -> Set<String> {
        try db.dbQueue.read { grdb in
            let rows = try AgentAction
                .filter(Column("status") == AgentActionStatus.pending.rawValue)
                .fetchAll(grdb)
            return Set(rows.map { "\($0.service)|\($0.conversationId)" })
        }
    }

    private func persist(_ action: AgentAction) throws {
        try db.dbQueue.write { grdb in
            var a = action
            try a.insert(grdb)
        }
    }
}
