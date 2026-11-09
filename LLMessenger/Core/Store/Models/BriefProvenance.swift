// LLMessenger/Core/Store/Models/BriefProvenance.swift
import GRDB
import Foundation

/// Which conversations' content went into the LLM prompt that produced a brief.
/// Cards are generated from one shared prompt, so any card may quote any of these
/// conversations; MCP uses this set to decide whether a digest may be shared.
struct BriefProvenance: Equatable, Sendable {
    var conversations: Set<BriefConversationKey> = []
    /// True when some prompt content came from conversations that could not be
    /// enumerated (e.g. a stored summary from a brief that predates provenance).
    /// An incomplete provenance can never be proven free of a Local-only chat.
    var incomplete = false

    mutating func formUnion(_ other: BriefProvenance) {
        conversations.formUnion(other.conversations)
        incomplete = incomplete || other.incomplete
    }
}

/// One row of `briefProvenance`: either a (service, conversationId) that fed the
/// brief, or the single "incomplete" sentinel row (empty service and conversation).
struct BriefProvenanceRecord: Codable, FetchableRecord, PersistableRecord {
    var briefId: Int64
    var service: String
    var conversationId: String
    var isIncompleteMarker: Bool

    static let databaseTableName = "briefProvenance"
}
