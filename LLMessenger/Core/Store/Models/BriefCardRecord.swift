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
    var needsReply: Bool
    var reason: String?
    var grounding: String
    var actionItems: String
    var callbackText: String?
    var sourceMessageIds: String
    var createdAt: Date

    static let databaseTableName = "briefCards"

    init(id: String,
         briefId: Int64,
         service: String,
         conversationId: String,
         conversationTitle: String?,
         headline: String,
         priority: String,
         summary: String,
         needsReply: Bool = false,
         reason: String? = nil,
         grounding: String = "direct",
         actionItems: String,
         callbackText: String?,
         sourceMessageIds: String,
         createdAt: Date) {
        self.id = id
        self.briefId = briefId
        self.service = service
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.headline = headline
        self.priority = priority
        self.summary = summary
        self.needsReply = needsReply
        self.reason = reason
        self.grounding = grounding
        self.actionItems = actionItems
        self.callbackText = callbackText
        self.sourceMessageIds = sourceMessageIds
        self.createdAt = createdAt
    }
}
