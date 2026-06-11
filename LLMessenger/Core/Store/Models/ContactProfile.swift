import GRDB
import Foundation

struct ContactProfile: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var service: String
    var conversationId: String
    var displayName: String
    var notes: String?
    var lastTopics: String?
    var pendingAsk: String?
    var updatedAt: Date

    static let databaseTableName = "contactProfiles"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
