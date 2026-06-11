import GRDB
import Foundation

struct PriorityRule: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var contactPattern: String?
    var keywordPattern: String?
    var service: String?
    var setPriority: String?
    var suppress: Bool
    var alwaysNotify: Bool
    var sortOrder: Int
    var createdAt: Date

    static let databaseTableName = "priorityRules"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
