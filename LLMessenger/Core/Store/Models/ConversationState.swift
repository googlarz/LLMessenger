import GRDB
import Foundation

struct ConversationState: Codable, FetchableRecord, PersistableRecord {
    var service: String
    var conversationId: String
    var lastSeenMessageId: String?
    var lastSummarizedMessageId: String?
    var rollingSummary: String?
    var participants: String?
    var knownEntities: String?
    var unresolvedActions: String?
    var lastBriefCardId: String?
    var prioritySignals: String?
    var sourceMessageIds: String?
    var updatedAt: Date

    static let databaseTableName = "conversationState"
}
