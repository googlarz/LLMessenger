import GRDB
import Foundation

struct TriageEvent: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var service: String
    var conversationId: String
    var priority: String       // "high" | "medium" | "low"
    var needsReply: Bool
    var reason: String
    var triggeredBy: String    // "rule" | "llm"
    var notified: Bool
    var createdAt: Date

    static let databaseTableName = "triageEvents"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
