import GRDB
import Foundation

struct Brief: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var createdAt: Date
    var status: String          // "ready" | "open" | "idle"
    var services: String        // JSON-encoded [String]
    var openingSummary: String?
    var notificationText: String
    var episodicSummary: String?

    static let databaseTableName = "briefs"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
