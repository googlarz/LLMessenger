import GRDB
import Foundation

struct Message: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var briefId: Int64?
    var service: String
    var conversationId: String
    var messageId: String       // native service ID — unique per (service, messageId)
    var sender: String
    var text: String
    var timestamp: Date
    var isSent: Bool

    static let databaseTableName = "messages"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
