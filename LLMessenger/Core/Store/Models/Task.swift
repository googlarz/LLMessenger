import GRDB
import Foundation

struct BriefTask: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var briefCardId: String
    var text: String
    var completedAt: Date?
    var createdAt: Date

    static let databaseTableName = "tasks"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
