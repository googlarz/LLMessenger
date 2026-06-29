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

        private static let formatter = ISO8601DateFormatter()

        var start: Date? { Self.formatter.date(from: startISO) }
        var end: Date? { Self.formatter.date(from: endISO) }
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
