import GRDB
import Foundation

enum BriefCardSourceRole: String, Codable {
    case newMessage = "new_message"
    case recentContext = "recent_context"
    case unresolvedAction = "unresolved_action"
    case quote
    case callback
}

struct BriefCardSource: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var briefCardId: String
    var messageRowId: Int64?
    var service: String
    var messageId: String
    var sourceRole: String
    var quoteText: String?
    var createdAt: Date

    static let databaseTableName = "briefCardSources"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
