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

struct AgentAction: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
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
    /// P2: when status == "scheduled", the instant the delegated auto-send fires.
    var scheduledAt: Date? = nil
    /// P3: the commitment this follow_up was generated for. Used to dedupe one pending
    /// follow-up per commitment. nil for non-follow_up actions.
    var commitmentId: Int64? = nil

    static let databaseTableName = "agentActions"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var kindEnum: AgentActionKind? { AgentActionKind(rawValue: kind) }
    var riskEnum: AgentActionRisk { AgentActionRisk(rawValue: riskLevel) ?? .normal }
    var statusEnum: AgentActionStatus { AgentActionStatus(rawValue: status) ?? .pending }

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
