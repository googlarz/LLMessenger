// LLMessenger/Core/Commitments/CommitmentDeriver.swift
//
// Extracts explicit promises in both directions from recent conversations and
// persists them as Commitment rows. Mirrors OwedReplyDeriver's per-conversation
// gather pattern and BriefEngine's validated-JSON LLM contract: the LLM proposes,
// manual decoding validates, and only clean rows are persisted.
//
// Privacy: a conversation marked local_only is only mined when the client is
// local. never_draft conversations are skipped entirely — no LLM ever reads them,
// matching the reply/calendar paths' stronger guarantee. Dedupe is case-insensitive
// against existing OPEN commitments
// for the same conversation; fulfilled/dropped rows never block a re-add because
// they are not open, but the same open `what` is never duplicated.

import Foundation
import GRDB

struct CommitmentDeriver {

    func derive(db: AppDatabase,
                llmClient: any LLMClient,
                llmModel: String,
                horizonDays: Int = 21,
                now: Date = Date()) async throws -> [Commitment] {
        let cutoff = now.addingTimeInterval(-Double(horizonDays) * 86400)
        let repository = BriefRepository(database: db)

        let messages: [Message] = try await db.dbQueue.read { grdb in
            try Message
                .filter(Column("timestamp") >= cutoff)
                .order(Column("timestamp").asc)
                .fetchAll(grdb)
        }

        // Group by conversation, preserving the most recent display name + service.
        var byKey: [String: [Message]] = [:]
        for msg in messages {
            byKey["\(msg.service)|\(msg.conversationId)", default: []].append(msg)
        }

        var inserted: [Commitment] = []

        let watermarkKey = "commitmentDeriverWatermarks"
        var watermarks = UserDefaults.standard.dictionary(forKey: watermarkKey) as? [String: Double] ?? [:]

        for (convKey, convMessages) in byKey {
            guard let last = convMessages.last else { continue }
            let service = last.service
            let conversationId = last.conversationId
            let conversationName = last.conversationName ?? conversationId

            // Skip if no new messages since last derivation run for this conversation.
            let latestTimestamp = convMessages.map { $0.timestamp.timeIntervalSince1970 }.max() ?? 0
            if let seen = watermarks[convKey], seen >= latestTimestamp { continue }

            let ctx = (try? repository.fetchConversationContext(
                service: service, conversationId: conversationId)) ?? nil
            // never_draft: no LLM ever touches this conversation, mirroring the reply
            // and calendar paths' stronger privacy guarantee.
            if ctx?.privacyOverride == "never_draft" { continue }
            // local_only: only mine on a local model.
            if ctx?.privacyOverride == "local_only", !llmClient.isLocal { continue }

            watermarks[convKey] = latestTimestamp

            let extracted = await extract(
                messages: convMessages,
                service: service,
                conversationName: conversationName,
                llmClient: llmClient,
                llmModel: llmModel)
            guard !extracted.isEmpty else { continue }

            let existing = (try? repository.fetchOpenCommitments(
                service: service, conversationId: conversationId)) ?? []
            var existingWhats = Set(existing.map { $0.what.lowercased() })

            for item in extracted {
                let normalized = item.what.lowercased()
                if existingWhats.contains(normalized) { continue }
                existingWhats.insert(normalized)

                let dueAt = item.dueHint.flatMap { Self.parseDueDate($0, now: now) }
                var commitment = Commitment(
                    id: nil,
                    direction: item.direction.rawValue,
                    service: service,
                    conversationId: conversationId,
                    conversationName: conversationName,
                    what: item.what,
                    dueAt: dueAt,
                    evidenceMessageId: item.evidenceMessageId,
                    status: CommitmentStatus.open.rawValue,
                    createdAt: now)
                if let id = try? repository.insertCommitment(commitment) {
                    commitment.id = id
                    inserted.append(commitment)
                }
            }
        }

        UserDefaults.standard.set(watermarks, forKey: watermarkKey)
        return inserted
    }

    // MARK: - LLM extraction (validated JSON, manual decode)

    private struct ExtractedCommitment {
        let direction: CommitmentDirection
        let what: String
        let dueHint: String?
        let evidenceMessageId: String?
    }

    private func extract(messages: [Message],
                         service: String,
                         conversationName: String,
                         llmClient: any LLMClient,
                         llmModel: String) async -> [ExtractedCommitment] {
        // Cap the transcript so a long thread can't blow the prompt budget.
        let recent = messages.suffix(40)
        let transcript = recent.map { msg in
            let who = msg.isSent ? "ME" : msg.sender
            return "[\(msg.messageId)] \(who): \(msg.text)"
        }.joined(separator: "\n")

        let userContent = """
        Extract explicit promises (commitments) from this conversation. A commitment is a
        concrete thing someone said they would do — "I'll send the photos", "I'll review by
        Friday", "I'll get you the cap table Wed". Ignore vague intentions, questions, and
        small talk.

        Direction:
        - "i_owe": ME promised to do something (a message sent by ME).
        - "they_owe": the other party promised something (an inbound message).

        Conversation: \(conversationName) (\(Theme.serviceName(service)))
        Transcript (each line is "[messageId] sender: text"):
        \(transcript)

        Respond with ONLY a JSON object (no markdown fences):
        {"commitments": [{"direction": "i_owe"|"they_owe", "what": "<short paraphrase of the promise>", "dueHint": "<relative date phrase like 'Friday' or 'tomorrow', or empty>", "evidenceMessageId": "<the messageId the promise came from>"}]}
        If there are no commitments, respond with {"commitments": []}.
        """

        let llmMessages: [LLMMessage] = [
            LLMMessage(role: .system, content: "You extract explicit commitments from chats. Output only valid JSON."),
            LLMMessage(role: .user, content: userContent)
        ]

        let response: LLMResponse
        do {
            response = try await llmClient.complete(model: llmModel, messages: llmMessages, maxTokens: 500)
        } catch {
            return []
        }

        return decodeAndValidate(response.text)
    }

    private struct ExtractionJSON: Codable {
        struct Item: Codable {
            let direction: String
            let what: String
            let dueHint: String?
            let evidenceMessageId: String?
        }
        let commitments: [Item]
    }

    private func decodeAndValidate(_ text: String) -> [ExtractedCommitment] {
        let clean = Self.stripMarkdownFences(text)
        guard let data = clean.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ExtractionJSON.self, from: data) else { return [] }

        var result: [ExtractedCommitment] = []
        for item in parsed.commitments {
            guard let direction = CommitmentDirection(rawValue: item.direction) else { continue }
            let what = item.what.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !what.isEmpty else { continue }
            let hint = item.dueHint?.trimmingCharacters(in: .whitespacesAndNewlines)
            let evidence = item.evidenceMessageId?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(ExtractedCommitment(
                direction: direction,
                what: what,
                dueHint: (hint?.isEmpty == false) ? hint : nil,
                evidenceMessageId: (evidence?.isEmpty == false) ? evidence : nil))
        }
        return result
    }

    private static func stripMarkdownFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        return trimmed
            .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Relative due-date parsing

    private static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7
    ]

    /// Best-effort relative parsing: "today", "tomorrow", weekday names. Returns the
    /// next occurrence at the start of that day. Returns nil when the phrase is unclear.
    static func parseDueDate(_ hint: String, now: Date, calendar: Calendar = .current) -> Date? {
        let lower = hint.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }
        let startOfToday = calendar.startOfDay(for: now)

        if lower.contains("today") { return startOfToday }
        if lower.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: startOfToday)
        }

        for (name, weekday) in weekdays where lower.contains(name) {
            let todayWeekday = calendar.component(.weekday, from: startOfToday)
            var delta = weekday - todayWeekday
            if delta <= 0 { delta += 7 }   // always the next occurrence
            return calendar.date(byAdding: .day, value: delta, to: startOfToday)
        }
        return nil
    }
}
