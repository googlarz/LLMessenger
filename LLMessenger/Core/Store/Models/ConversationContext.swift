// LLMessenger/Core/Store/Models/ConversationContext.swift
import GRDB
import Foundation

/// User-set metadata for a conversation that the LLM uses during brief generation.
/// Injected into each conversation block header so the model knows relationship context
/// and respects explicit priority overrides.
struct ConversationContext: Codable, FetchableRecord, PersistableRecord {
    var service: String
    var conversationId: String
    /// Free-text relationship label, e.g. "manager", "client", "low noise group".
    var label: String
    /// Explicit priority override: "auto", "high", "med", "low".
    /// "auto" means let the LLM decide; any other value is enforced in the prompt.
    var priorityHint: String
    var updatedAt: Date

    static let databaseTableName = "conversationContexts"
}
