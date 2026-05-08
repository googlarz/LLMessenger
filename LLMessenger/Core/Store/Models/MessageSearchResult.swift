// LLMessenger/Core/Store/Models/MessageSearchResult.swift
import Foundation

/// Result from an FTS5 full-text search over the messages table.
struct MessageSearchResult {
    let messageRowId: Int64
    let service: String
    let conversationId: String
    let conversationName: String?
    let sender: String
    /// FTS5 snippet with matched terms surrounded by `<<` and `>>`.
    let snippet: String
    let timestamp: Date
}
