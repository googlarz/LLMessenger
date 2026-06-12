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
    /// "HH:mm" — nil means no quiet window for this rule.
    var quietStart: String?
    var quietEnd: String?

    static let databaseTableName = "priorityRules"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
