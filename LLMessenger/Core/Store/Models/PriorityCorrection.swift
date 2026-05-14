// LLMessenger/Core/Store/Models/PriorityCorrection.swift
import GRDB
import Foundation

/// Records when the user corrects a card's LLM-assigned priority.
/// Recent corrections are injected into the summarizer prompt as few-shot
/// calibration examples so the model learns the user's preferences over time.
struct PriorityCorrection: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var service: String
    var conversationId: String
    /// Headline of the card, for few-shot context in the prompt.
    var cardHeadline: String
    /// Priority the LLM originally assigned ("high", "med", "low").
    var llmPriority: String
    /// Priority the user corrected it to.
    var userPriority: String
    var createdAt: Date

    static let databaseTableName = "priorityCorrections"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
