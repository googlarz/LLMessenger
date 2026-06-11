import GRDB
import Foundation

struct Task: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var briefCardId: Int64
    var text: String
    var completedAt: Date?
    var createdAt: Date

    static let databaseTableName = "tasks"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
