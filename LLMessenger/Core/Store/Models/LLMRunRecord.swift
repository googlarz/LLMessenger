import GRDB
import Foundation

struct LLMRunRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var briefId: Int64?
    var service: String?
    var conversationId: String?
    var backend: String
    var model: String
    var startedAt: Date
    var completedAt: Date?
    var status: String
    var errorCategory: String?
    var promptHash: String?
    var responseHash: String?
    var inputTokenEstimate: Int?
    var outputTokenEstimate: Int?

    static let databaseTableName = "llmRuns"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
