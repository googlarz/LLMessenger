// LLMessenger/Core/Agent/AgentAction.swift
//
// A proposed action the agent surfaces for user approval. Persisted to the
// `agentActions` table (v22_agent migration). In P1 the only kind is "reply".

import GRDB
import Foundation

enum AgentActionKind: String, Codable {
    case reply
    case followUp = "follow_up"
    case calendarHold = "calendar_hold"
    case rsvp
    case ack
}

enum AgentActionRisk: String, Codable {
    case low
    case normal
    case high
}

enum AgentActionStatus: String, Codable {
    case pending
    case approved
    case executing
    case done
    case failed
    case skipped
    /// P2: armed for delegated auto-send. Has a non-nil `scheduledAt` fire time;
    /// the user can Undo (revert to pending) before the timer fires.
    case scheduled
}

enum AgentActionScheduleKind: String, Codable {
    case manual
    case delegated
}

struct AgentAction: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let manualApproveUndoWindow: TimeInterval = 5
    static let delegatedUndoWindow: TimeInterval = 30

    var id: Int64?
    var kind: String
    var service: String
    var conversationId: String
    var conversationName: String
    var title: String
    var payload: String        // JSON: drafted text / event details
    var reasoning: String
    var confidence: Double
    var riskLevel: String
    var status: String
    var createdAt: Date
    var resolvedAt: Date?
    /// When status == "scheduled", the instant the send leaves the Undo window.
    var scheduledAt: Date? = nil
    /// Distinguishes a user-staged approve from a delegated auto-send.
    var scheduledKind: String? = nil
    /// The original Undo window duration, used by UI progress and timer recovery.
    var scheduledWindow: Double? = nil
    /// P3: the commitment this follow_up was generated for. Used to dedupe one pending
    /// follow-up per commitment. nil for non-follow_up actions.
    var commitmentId: Int64? = nil
    /// "Maybe": the agent drafted this but isn't sure the message actually needs action.
    /// Routed to the Maybe surface ("your call") instead of the Ready queue. Default false.
    var isMaybe: Bool = false

    static let databaseTableName = "agentActions"

    /// Written only by the MCP server (never taken from a client) so rows it queued
    /// can be recognised without a schema change.
    static let externalAgentReasoning = "Proposed by an external agent via MCP."

    var isExternalProposal: Bool { reasoning == Self.externalAgentReasoning }

    /// Marks a reply the user wrote themselves in the Reply composer.
    static let userComposedReasoning = "Written by you in the Reply composer."

    var isUserComposed: Bool { reasoning == Self.userComposedReasoning }

    /// Provenance markers the app writes itself. Model output must never carry
    /// one: a prompt-injected message could otherwise make an AI draft look
    /// user-written or external. Every path that stores model-written reasoning
    /// passes it through `sanitizedModelReasoning`.
    static let reservedReasoningMarkers: [String] = [externalAgentReasoning, userComposedReasoning]

    static let neutralModelReasoning = "Drafted by LLMessenger."

    static func sanitizedModelReasoning(_ text: String) -> String {
        let folded = text.lowercased()
        let forged = reservedReasoningMarkers.contains { marker in
            let m = marker.lowercased()
            return folded.contains(m)
                || folded.contains(m.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        return forged ? neutralModelReasoning : text
    }

    /// External proposals are approved one at a time, never in a multi-select batch.
    /// A user-composed reply is never batched either: it only ever sends from its
    /// own composer (or its own row after an interrupted undo window).
    var isBatchEligible: Bool {
        statusEnum == .pending
            && !isMaybe
            && riskEnum != .high
            && (kindEnum == .reply || kindEnum == .ack)
            && !isExternalProposal
            && !isUserComposed
    }

    /// A reply the user wrote. Normal risk and full confidence; replies and
    /// follow-ups are never delegatable (AgentDelegation.delegatableKinds), never
    /// "low" risk (batchApproveLowRisk) and never batch-eligible (above).
    static func userComposed(service: String,
                             conversationId: String,
                             conversationName: String,
                             text: String,
                             commitmentId: Int64?,
                             now: Date = Date()) -> AgentAction {
        AgentAction(
            id: nil,
            kind: (commitmentId == nil ? AgentActionKind.reply : .followUp).rawValue,
            service: service,
            conversationId: conversationId,
            conversationName: conversationName,
            title: "Your reply",
            payload: encodeReplyPayload(text),
            reasoning: userComposedReasoning,
            confidence: 1,
            riskLevel: AgentActionRisk.normal.rawValue,
            status: AgentActionStatus.pending.rawValue,
            createdAt: now,
            resolvedAt: nil,
            commitmentId: commitmentId,
            isMaybe: false)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var kindEnum: AgentActionKind? { AgentActionKind(rawValue: kind) }
    var riskEnum: AgentActionRisk { AgentActionRisk(rawValue: riskLevel) ?? .normal }
    var statusEnum: AgentActionStatus { AgentActionStatus(rawValue: status) ?? .pending }
    var scheduledKindEnum: AgentActionScheduleKind? {
        guard let scheduledKind else { return nil }
        return AgentActionScheduleKind(rawValue: scheduledKind)
    }
    /// The scheduled send the user staged last — what Undo should cancel. Not the
    /// newest createdAt (batch approve stages old actions), and not the latest
    /// scheduledAt (a 30s delegated send staged earlier can fire after a 5s manual
    /// one staged later): staging time is scheduledAt minus the action's own window.
    static func mostRecentlyStaged(in actions: [AgentAction]) -> AgentAction? {
        actions
            .filter { $0.statusEnum == .scheduled }
            .max { lhs, rhs in
                let lhsStagedAt = (lhs.scheduledAt ?? .distantPast).addingTimeInterval(-lhs.scheduledUndoWindow)
                let rhsStagedAt = (rhs.scheduledAt ?? .distantPast).addingTimeInterval(-rhs.scheduledUndoWindow)
                return lhsStagedAt < rhsStagedAt
            }
    }

    var scheduledUndoWindow: TimeInterval {
        if let scheduledWindow, scheduledWindow > 0 { return scheduledWindow }
        switch scheduledKindEnum {
        case .manual:
            return Self.manualApproveUndoWindow
        case .delegated, .none:
            return Self.delegatedUndoWindow
        }
    }

    // MARK: - Reply payload

    /// Typed payload for a "reply" action.
    struct ReplyPayload: Codable {
        var draftText: String
        /// Plain-language reason the last send failed, kept with the row so the
        /// "Couldn't send" line survives a restart. Older rows simply lack it.
        var failureReason: String? = nil
    }

    var failureReason: String? {
        let reason = replyPayload?.failureReason
        return (reason?.isEmpty ?? true) ? nil : reason
    }

    /// This row's payload with the failure reason recorded, draft text untouched.
    /// Returns nil if the payload isn't a reply payload (nothing to record on).
    func payloadRecordingFailure(_ reason: String) -> String? {
        guard var decoded = replyPayload else { return nil }
        decoded.failureReason = reason
        guard let data = try? JSONEncoder().encode(decoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var replyPayload: ReplyPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReplyPayload.self, from: data)
    }

    static func encodeReplyPayload(_ draftText: String) -> String {
        let payload = ReplyPayload(draftText: draftText)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - Calendar payload (calendar_hold / rsvp)

    /// Typed payload for "calendar_hold" and the event side of "rsvp".
    /// Dates are ISO8601 strings so the JSON column stays human-readable.
    struct CalendarPayload: Codable {
        var title: String
        var startISO: String
        var endISO: String
        var notes: String?
        /// For rsvp: the reply text to send alongside the optional event.
        var replyText: String?

        var start: Date? { ISO8601DateFormatter().date(from: startISO) }
        var end: Date? { ISO8601DateFormatter().date(from: endISO) }
    }

    var calendarPayload: CalendarPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CalendarPayload.self, from: data)
    }

    static func encodeCalendarPayload(_ payload: CalendarPayload) -> String {
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
