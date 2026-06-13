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

    // v2 "Understand" fields. All optional so pre-v19 rows (NULL columns) decode.
    /// Free-text relationship, e.g. "spouse", "direct report".
    var relationship: String?
    /// JSON array string of topics that matter for this conversation.
    var importantTopics: String?
    /// JSON array string of topics that are noise for this conversation.
    var noiseTopics: String?
    /// JSON array string of senders that matter most.
    var keySenders: String?
    /// Free-text note injected into the brief prompt.
    var contextNote: String?
    /// Free-text expectation, e.g. "reply within the hour".
    var responseExpectation: String?
    /// "local_only" | "never_draft" | nil.
    var privacyOverride: String?
    /// JSON array string of glossary aliases, e.g. "The Hall = home venue".
    var aliases: String?
    /// Free-text preferred tone for drafting, e.g. "casual, lots of emoji".
    var tone: String?

    init(service: String,
         conversationId: String,
         label: String,
         priorityHint: String,
         updatedAt: Date,
         relationship: String? = nil,
         importantTopics: String? = nil,
         noiseTopics: String? = nil,
         keySenders: String? = nil,
         contextNote: String? = nil,
         responseExpectation: String? = nil,
         privacyOverride: String? = nil,
         aliases: String? = nil,
         tone: String? = nil) {
        self.service = service
        self.conversationId = conversationId
        self.label = label
        self.priorityHint = priorityHint
        self.updatedAt = updatedAt
        self.relationship = relationship
        self.importantTopics = importantTopics
        self.noiseTopics = noiseTopics
        self.keySenders = keySenders
        self.contextNote = contextNote
        self.responseExpectation = responseExpectation
        self.privacyOverride = privacyOverride
        self.aliases = aliases
        self.tone = tone
    }

    static let databaseTableName = "conversationContexts"

    var importantTopicsList: [String] {
        get { Self.decodeArray(importantTopics) }
        set { importantTopics = Self.encodeArray(newValue) }
    }

    var noiseTopicsList: [String] {
        get { Self.decodeArray(noiseTopics) }
        set { noiseTopics = Self.encodeArray(newValue) }
    }

    var keySendersList: [String] {
        get { Self.decodeArray(keySenders) }
        set { keySenders = Self.encodeArray(newValue) }
    }

    var aliasesList: [String] {
        get { Self.decodeArray(aliases) }
        set { aliases = Self.encodeArray(newValue) }
    }

    private static func decodeArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array.filter { !$0.isEmpty }
    }

    private static func encodeArray(_ values: [String]) -> String? {
        let cleaned = values.filter { !$0.isEmpty }
        guard !cleaned.isEmpty, let data = try? JSONEncoder().encode(cleaned),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
