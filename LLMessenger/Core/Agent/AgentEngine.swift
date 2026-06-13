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

        // P3: derive commitments, then propose follow-ups for due ones.
        if await deriveCommitmentsAndProposeFollowUps() { produced = true }

        // P4: detect scheduling intent and propose calendar_hold / rsvp actions.
        if await proposeCalendarActions() { produced = true }

        if produced { await onActionsChanged?() }
    }

    // MARK: - P3 Commitments + follow-ups

    /// Number of days a no-due commitment must age before a follow-up is proposed.
    static let staleCommitmentDays: Double = 3

    /// Derives commitments for recent conversations, then proposes a follow_up for
    /// every OPEN commitment that is due. Returns true if any action was persisted.
    @discardableResult
    func deriveCommitmentsAndProposeFollowUps(now: Date = Date()) async -> Bool {
        _ = try? await CommitmentDeriver().derive(db: db, llmClient: llmClient, llmModel: llmModel, now: now)

        let open = (try? repository.fetchOpenCommitments()) ?? []
        let existingKeys = (try? pendingFollowUpKeys()) ?? []
        var produced = false

        for commitment in open {
            guard let id = commitment.id, Self.isDue(commitment, now: now) else { continue }
            // Dedupe: one pending follow-up per commitment.
            if existingKeys.contains("commitment:\(id)") { continue }
            guard let action = Self.followUpAction(for: commitment) else { continue }
            if (try? persist(action)) != nil { produced = true }
        }
        return produced
    }

    /// A commitment is "due" when its dueAt has passed, or — with no due date — it has
    /// aged past the stale threshold.
    static func isDue(_ commitment: Commitment, now: Date) -> Bool {
        if let dueAt = commitment.dueAt { return dueAt <= now }
        return now.timeIntervalSince(commitment.createdAt) >= staleCommitmentDays * 86400
    }

    /// Builds the follow_up AgentAction for a due commitment. follow_up is never
    /// delegatable, so riskLevel is "normal". The drafted nudge differs by direction.
    static func followUpAction(for commitment: Commitment) -> AgentAction? {
        guard let id = commitment.id else { return nil }
        let draft: String
        let title: String
        let reasoning: String
        switch commitment.directionEnum {
        case .iOwe:
            draft = "Sending \(commitment.what) now — sorry for the delay."
            title = "Deliver: \(commitment.what)"
            reasoning = "You promised this and it's now due."
        case .theyOwe, .none:
            draft = "Hey, any luck with \(commitment.what)?"
            title = "Chase: \(commitment.what)"
            reasoning = "They promised this and it's now due."
        }
        return AgentAction(
            id: nil,
            kind: AgentActionKind.followUp.rawValue,
            service: commitment.service,
            conversationId: commitment.conversationId,
            conversationName: commitment.conversationName,
            title: title,
            payload: AgentAction.encodeReplyPayload(draft),
            reasoning: reasoning,
            confidence: 0.6,
            riskLevel: AgentActionRisk.normal.rawValue,
            status: AgentActionStatus.pending.rawValue,
            createdAt: Date(),
            resolvedAt: nil,
            scheduledAt: nil,
            commitmentId: id)
    }

    // MARK: - P4 Calendar actions

    /// Detects scheduling intent in recent inbound messages and proposes a calendar_hold
    /// for proposed times or an rsvp for invites. Conservative: proposes nothing unless
    /// the LLM clearly identifies a schedulable event. Returns true if anything persisted.
    @discardableResult
    func proposeCalendarActions(now: Date = Date()) async -> Bool {
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let inbound: [Message] = (try? await db.dbQueue.read { grdb in
            try Message
                .filter(Column("timestamp") >= cutoff)
                .filter(Column("isSent") == false)
                .order(Column("timestamp").asc)
                .fetchAll(grdb)
        }) ?? []
        guard !inbound.isEmpty else { return false }

        var byKey: [String: [Message]] = [:]
        for msg in inbound { byKey["\(msg.service)|\(msg.conversationId)", default: []].append(msg) }

        let existingKeys = (try? pendingActionKeys()) ?? []
        var produced = false

        for (key, msgs) in byKey {
            guard let last = msgs.last else { continue }
            // Dedupe: one pending calendar action per conversation.
            if existingKeys.contains(key) { continue }

            let ctx = (try? repository.fetchConversationContext(
                service: last.service, conversationId: last.conversationId)) ?? nil
            if ctx?.privacyOverride == "never_draft" { continue }
            if ctx?.privacyOverride == "local_only", !llmClient.isLocal { continue }

            for action in await detectSchedule(messages: msgs, last: last) {
                if (try? persist(action)) != nil { produced = true }
            }
        }
        return produced
    }

    private func detectSchedule(messages: [Message], last: Message) async -> [AgentAction] {
        let recent = messages.suffix(30)
        let transcript = recent.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
        let conversationName = last.conversationName ?? last.conversationId

        let userContent = """
        Detect concrete scheduling proposals in this conversation — a specific meeting,
        call, or event with a time. Ignore vague "let's meet sometime" with no time.

        For each, decide:
        - isInvite=true if it's an invitation expecting a yes/no.
        - isInvite=false if it's just a time the user might want to block/hold.

        Conversation: \(conversationName)
        Transcript:
        \(transcript)

        Current time is \(ISO8601DateFormatter().string(from: Date())).
        Respond with ONLY a JSON object (no markdown fences):
        {"schedule": [{"title": "<event title>", "startISO": "<ISO8601>", "endISO": "<ISO8601>", "isInvite": true|false}]}
        If nothing is clearly schedulable, respond with {"schedule": []}.
        """

        let llmMessages: [LLMMessage] = [
            LLMMessage(role: .system, content: "You detect calendar events in chats. Output only valid JSON."),
            LLMMessage(role: .user, content: userContent)
        ]

        let response: LLMResponse
        do {
            response = try await llmClient.complete(model: llmModel, messages: llmMessages, maxTokens: 400)
        } catch {
            return []
        }

        let items = Self.decodeSchedule(response.text)
        return items.compactMap { item in
            let payload = AgentAction.CalendarPayload(
                title: item.title,
                startISO: item.startISO,
                endISO: item.endISO,
                notes: "From \(conversationName) (\(Theme.serviceName(last.service)))",
                replyText: item.isInvite ? "Yes, that works for me — see you then." : nil)
            // Validate the dates parse before proposing.
            guard payload.start != nil, payload.end != nil else { return nil }

            return AgentAction(
                id: nil,
                kind: (item.isInvite ? AgentActionKind.rsvp : AgentActionKind.calendarHold).rawValue,
                service: last.service,
                conversationId: last.conversationId,
                conversationName: conversationName,
                title: item.title,
                payload: AgentAction.encodeCalendarPayload(payload),
                reasoning: item.isInvite ? "An invite that needs a yes/no." : "A proposed time you may want to hold.",
                confidence: 0.6,
                riskLevel: AgentActionRisk.normal.rawValue,
                status: AgentActionStatus.pending.rawValue,
                createdAt: Date(),
                resolvedAt: nil)
        }
    }

    struct ScheduleJSON: Codable {
        struct Item: Codable {
            let title: String
            let startISO: String
            let endISO: String
            let isInvite: Bool
        }
        let schedule: [Item]
    }

    static func decodeSchedule(_ text: String) -> [ScheduleJSON.Item] {
        let clean = staticStripFences(text)
        guard let data = clean.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ScheduleJSON.self, from: data) else { return [] }
        return parsed.schedule.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func staticStripFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        return trimmed
            .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Keys "commitment:<id>" of pending follow-up actions, for dedupe.
    private func pendingFollowUpKeys() throws -> Set<String> {
        try db.dbQueue.read { grdb in
            let rows = try AgentAction
                .filter(Column("status") == AgentActionStatus.pending.rawValue)
                .filter(Column("commitmentId") != nil)
                .fetchAll(grdb)
            return Set(rows.compactMap { $0.commitmentId.map { "commitment:\($0)" } })
        }
    }

    private func persist(_ action: AgentAction) throws {
        try db.dbQueue.write { grdb in
            var a = action
            try a.insert(grdb)
        }
    }
}
