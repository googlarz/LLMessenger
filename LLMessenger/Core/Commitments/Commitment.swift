// LLMessenger/Core/Commitments/Commitment.swift
//
// A tracked promise — something you owe someone, or something they owe you.
// Persisted to the `commitments` table (v22_agent migration). Used in P3;
// the model exists now so the schema and record stay in lockstep.

import GRDB
import Foundation

enum CommitmentDirection: String, Codable {
    case iOwe = "i_owe"
    case theyOwe = "they_owe"
}

enum CommitmentStatus: String, Codable {
    case open
    case fulfilled
    case dropped
}

struct Commitment: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var direction: String
    var service: String
    var conversationId: String
    var conversationName: String
    var what: String
    var dueAt: Date?
    var evidenceMessageId: String?
    var status: String
    var createdAt: Date

    static let databaseTableName = "commitments"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var directionEnum: CommitmentDirection? { CommitmentDirection(rawValue: direction) }
    var statusEnum: CommitmentStatus { CommitmentStatus(rawValue: status) ?? .open }
}
