import GRDB
import Foundation

struct BriefCardRecord: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var briefId: Int64
    var service: String
    var conversationId: String
    var conversationTitle: String?
    var headline: String
    var priority: String
    var summary: String
    var actionItems: String
    var callbackText: String?
    var sourceMessageIds: String
    var createdAt: Date

    static let databaseTableName = "briefCards"
}
