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
    var logicalId: String? = nil
    var position: Int = 0
    var messageCount: Int = 0
    var threadCount: Int = 0
    var peopleCount: Int = 0
    var quotes: String = "[]"
    var collapsed: Bool = false

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
         createdAt: Date,
         logicalId: String? = nil,
         position: Int = 0,
         messageCount: Int = 0,
         threadCount: Int = 0,
         peopleCount: Int = 0,
         quotes: String = "[]",
         collapsed: Bool = false) {
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
        self.logicalId = logicalId
        self.position = position
        self.messageCount = messageCount
        self.threadCount = threadCount
        self.peopleCount = peopleCount
        self.quotes = quotes
        self.collapsed = collapsed
    }

    var briefCard: BriefCard {
        BriefCard(
            id: logicalId ?? id,
            service: service,
            conversationId: conversationId,
            conversationTitle: conversationTitle,
            headline: headline,
            priority: priority,
            counts: BriefCardCounts(
                messages: messageCount,
                threads: threadCount,
                people: peopleCount
            ),
            summary: summary,
            callback: callbackText,
            needsReply: needsReply,
            reason: reason,
            grounding: grounding,
            actionItems: decode([String].self, from: actionItems) ?? [],
            quotes: decode([BriefQuote].self, from: quotes) ?? [],
            sourceMessageIds: decode([String].self, from: sourceMessageIds) ?? [],
            collapsed: collapsed
        )
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from json: String) -> Value? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
