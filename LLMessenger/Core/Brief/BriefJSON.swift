import Foundation

struct BriefJSON: Codable {
    let totalMessages: Int?
    let totalThreads: Int?
    let totalPeople: Int?
    let cards: [BriefCard]

    var total_messages: Int? { totalMessages }
    var total_threads: Int? { totalThreads }
    var total_people: Int? { totalPeople }

    enum CodingKeys: String, CodingKey {
        case totalMessages = "total_messages"
        case totalThreads = "total_threads"
        case totalPeople = "total_people"
        case cards
    }
}

struct BriefCard: Codable, Identifiable {
    let id: String
    let service: String
    let conversationId: String
    let conversationTitle: String?
    let headline: String
    let priority: String
    let counts: BriefCardCounts
    let summary: String
    let callback: String?
    let actionItems: [String]
    let quotes: [BriefQuote]
    let sourceMessageIds: [String]
    /// Set at brief creation time by DigestOrdering — low-priority/noise cards are folded
    /// into the noise strip in the UI rather than rendered as full cards.
    let collapsed: Bool

    var conversation: String? { conversationTitle }
    var actions: [String] { actionItems }

    enum CodingKeys: String, CodingKey {
        case id
        case service
        case conversationId
        case conversationTitle
        case legacyConversation = "conversation"
        case headline
        case priority
        case counts
        case summary
        case callback
        case actionItems
        case legacyActions = "actions"
        case quotes
        case sourceMessageIds
        case collapsed
    }

    init(
        id: String,
        service: String,
        conversationId: String,
        conversationTitle: String?,
        headline: String,
        priority: String,
        counts: BriefCardCounts,
        summary: String,
        callback: String?,
        actionItems: [String],
        quotes: [BriefQuote],
        sourceMessageIds: [String],
        collapsed: Bool = false
    ) {
        self.id = id
        self.service = service
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.headline = headline
        self.priority = priority
        self.counts = counts
        self.summary = summary
        self.callback = callback
        self.actionItems = actionItems
        self.quotes = quotes
        self.sourceMessageIds = sourceMessageIds
        self.collapsed = collapsed
    }

    func withCollapsed(_ value: Bool) -> BriefCard {
        BriefCard(id: id, service: service, conversationId: conversationId,
                  conversationTitle: conversationTitle, headline: headline,
                  priority: priority, counts: counts, summary: summary,
                  callback: callback, actionItems: actionItems, quotes: quotes,
                  sourceMessageIds: sourceMessageIds, collapsed: value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        service = try container.decodeIfPresent(String.self, forKey: .service) ?? "unknown"
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
            ?? (try container.decodeIfPresent(String.self, forKey: .legacyConversation))
            ?? "unknown"
        conversationTitle = try container.decodeIfPresent(String.self, forKey: .conversationTitle)
            ?? (try container.decodeIfPresent(String.self, forKey: .legacyConversation))
        headline = try container.decode(String.self, forKey: .headline)
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "low"
        counts = try container.decodeIfPresent(BriefCardCounts.self, forKey: .counts) ?? .zero
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? headline
        // The LLM occasionally emits a bool or other non-string value for callback;
        // tolerate it as nil rather than failing the whole brief.
        callback = (try? container.decodeIfPresent(String.self, forKey: .callback)) ?? nil
        actionItems = try container.decodeIfPresent([String].self, forKey: .actionItems)
            ?? (try container.decodeIfPresent([String].self, forKey: .legacyActions))
            ?? []
        quotes = try container.decodeIfPresent([BriefQuote].self, forKey: .quotes) ?? []
        // The LLM formats messages as "[id=<msgId> | ...]" and sometimes copies the "id=" label
        // verbatim into sourceMessageIds (e.g. "id=541a06ac-...-1777702993542"). Strip it here so
        // validation, persistence, and evidence lookup all receive bare message IDs.
        sourceMessageIds = (try container.decodeIfPresent([String].self, forKey: .sourceMessageIds) ?? [])
            .map { $0.hasPrefix("id=") ? String($0.dropFirst(3)) : $0 }
        collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(service, forKey: .service)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encodeIfPresent(conversationTitle, forKey: .conversationTitle)
        try container.encode(headline, forKey: .headline)
        try container.encode(priority, forKey: .priority)
        try container.encode(counts, forKey: .counts)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(callback, forKey: .callback)
        try container.encode(actionItems, forKey: .actionItems)
        try container.encode(quotes, forKey: .quotes)
        try container.encode(sourceMessageIds, forKey: .sourceMessageIds)
        try container.encode(collapsed, forKey: .collapsed)
    }
}

struct BriefCardCounts: Codable {
    let messages: Int
    let threads: Int
    let people: Int

    static let zero = BriefCardCounts(messages: 0, threads: 0, people: 0)
}

struct BriefQuote: Codable {
    let messageId: String?
    let from: String
    let time: String
    let text: String

    init(messageId: String?, from: String, time: String, text: String) {
        self.messageId = messageId
        self.from = from
        self.time = time
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .messageId)
        messageId = raw.map { $0.hasPrefix("id=") ? String($0.dropFirst(3)) : $0 }
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}
