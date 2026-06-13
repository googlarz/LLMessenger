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
}
