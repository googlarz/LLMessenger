import GRDB
import Foundation

enum BriefStatus: String, Codable {
    case ready
    case open
    case idle
}

struct Brief: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var createdAt: Date
    var status: String          // stored as raw string for DB compat; use BriefStatus for logic
    var services: String        // JSON-encoded [String]
    var openingSummary: String?
    var notificationText: String
    var episodicSummary: String?

    static let databaseTableName = "briefs"

    var briefStatus: BriefStatus { BriefStatus(rawValue: status) ?? .idle }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
