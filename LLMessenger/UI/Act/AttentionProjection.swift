import Foundation

enum ActItem: Identifiable {
    case agentAction(AgentAction)
    case owedReply(OwedReply)

    var id: String {
        switch self {
        case .agentAction(let action):
            if let id = action.id { return "action-\(id)" }
            return [
                "action-new",
                action.service,
                action.conversationId,
                action.kind,
                action.title,
                "\(action.createdAt.timeIntervalSinceReferenceDate)",
                action.payload
            ].joined(separator: "|")
        case .owedReply(let reply):
            return "owed-\(reply.id)"
        }
    }

    var isPersonWaiting: Bool {
        switch self {
        case .agentAction(let action):
            return action.kindEnum == .reply || action.kindEnum == .ack
        case .owedReply:
            return true
        }
    }

    var service: String {
        switch self {
        case .agentAction(let action): return action.service
        case .owedReply(let reply): return reply.service
        }
    }

    var conversationId: String {
        switch self {
        case .agentAction(let action): return action.conversationId
        case .owedReply(let reply): return reply.conversationId
        }
    }

    var name: String {
        switch self {
        case .agentAction(let action): return action.conversationName
        case .owedReply(let reply): return reply.conversationName
        }
    }

    var preview: String {
        switch self {
        case .agentAction(let action): return action.replyPayload?.draftText ?? action.title
        case .owedReply(let reply): return reply.triggerText
        }
    }

    var triggeredAt: Date {
        switch self {
        case .agentAction(let action): return action.createdAt
        case .owedReply(let reply): return reply.triggeredAt
        }
    }

    func ageHours(now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(triggeredAt) / 3600))
    }

    var ageHours: Int { ageHours(now: Date()) }

    func isStale(now: Date = Date()) -> Bool {
        switch self {
        case .agentAction: return ageHours(now: now) > 48
        case .owedReply: return ageHours(now: now) > 72
        }
    }

    var isStale: Bool { isStale(now: Date()) }

    var typeIcon: String {
        switch self {
        case .agentAction(let action):
            switch action.kindEnum {
            case .reply: return "arrow.turn.up.left"
            case .followUp: return "clock.arrow.circlepath"
            case .calendarHold: return "calendar.badge.plus"
            case .rsvp: return "calendar.badge.checkmark"
            case .ack: return "hand.thumbsup"
            case .none: return "ellipsis"
            }
        case .owedReply:
            return "arrow.turn.up.left"
        }
    }

    var accessibilitySummary: String {
        "\(name), \(preview)"
    }
}

enum AttentionRanker {
    static func effectivePriority(_ cardPriority: String, context: ConversationContext?) -> String {
        switch context?.priorityHint {
        case "high": return "high"
        case "med", "medium": return "med"
        case "low": return "low"
        default: return cardPriority.lowercased()
        }
    }

    static func score(_ item: ActItem, context: ConversationContext?) -> Int {
        let contextScore: Int
        switch context?.priorityHint {
        case "high": contextScore = 3_000
        case "med", "medium": contextScore = 2_300
        case "low": contextScore = 1_000
        default: contextScore = 2_000
        }

        let waitingScore = item.isPersonWaiting ? 500 : 0
        let urgencyScore: Int
        switch item {
        case .agentAction(let action):
            let scheduled = action.statusEnum == .scheduled ? 300 : 0
            let risk = action.riskEnum == .high ? 150 : (action.riskEnum == .normal ? 75 : 0)
            urgencyScore = scheduled + risk + Int(max(0, min(action.confidence, 1)) * 100)
        case .owedReply(let reply):
            urgencyScore = max(0, min(reply.priorityRank, 3)) * 100
        }
        return contextScore + waitingScore + urgencyScore
    }

    static func score(card: BriefCardRecord, context: ConversationContext?) -> Int {
        let itemScore: Int
        switch effectivePriority(card.priority, context: context) {
        case "high": itemScore = 300
        case "med", "medium": itemScore = 200
        default: itemScore = 100
        }
        let contextScore: Int
        switch context?.priorityHint {
        case "high": contextScore = 3_000
        case "med", "medium": contextScore = 2_300
        case "low": contextScore = 1_000
        default: contextScore = 2_000
        }
        return contextScore + (card.needsReply ? 500 : 0) + itemScore
    }
}

enum ActItemSorter {
    static func sort(
        _ items: [ActItem],
        now: Date = Date(),
        contextFor: (String, String) -> ConversationContext?
    ) -> [ActItem] {
        let scored = items.map { item in
            (
                item: item,
                score: AttentionRanker.score(
                    item,
                    context: contextFor(item.service, item.conversationId)
                )
            )
        }
        return scored.sorted { lhs, rhs in
            let lhsStale = lhs.item.isStale(now: now)
            let rhsStale = rhs.item.isStale(now: now)
            if lhsStale != rhsStale { return !lhsStale }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.isPersonWaiting != rhs.item.isPersonWaiting { return lhs.item.isPersonWaiting }
            if lhs.item.triggeredAt != rhs.item.triggeredAt {
                return lhs.item.triggeredAt < rhs.item.triggeredAt
            }
            return lhs.item.id < rhs.item.id
        }.map(\.item)
    }
}

struct DigestAttentionSummary {
    var replyCount: Int
    var reviewCount: Int
    var quietCount: Int

    static let empty = DigestAttentionSummary(replyCount: 0, reviewCount: 0, quietCount: 0)
}

struct AttentionProjection {
    var actItems: [ActItem]
    var readyActions: [AgentAction]
    var maybeActions: [AgentAction]
    var owedRepliesWithoutDrafts: [OwedReply]
    var commitments: [Commitment]
    var tasks: [BriefTask]
    var latestDigest: DigestAttentionSummary
    var todayHighPriorityUnhandledCount: Int

    static let empty = AttentionProjection(
        actItems: [],
        readyActions: [],
        maybeActions: [],
        owedRepliesWithoutDrafts: [],
        commitments: [],
        tasks: [],
        latestDigest: .empty,
        todayHighPriorityUnhandledCount: 0
    )

    var actBadgeCount: Int { actItems.count }
    var readyActionCount: Int { readyActions.count }
    var waitingConversationCount: Int {
        Set(actItems.filter(\.isPersonWaiting).map { "\($0.service)|\($0.conversationId)" }).count
    }
    var promiseCount: Int { commitments.count + tasks.count }
    var isClear: Bool { actItems.isEmpty && promiseCount == 0 }

    static func build(
        briefs: [Brief],
        cardsByBriefID: [Int64: [BriefCard]],
        handledCardKeys: Set<String>,
        actions: [AgentAction],
        owedReplies: [OwedReply],
        commitments: [Commitment],
        tasks: [BriefTask],
        contextsByKey: [String: ConversationContext],
        now: Date = Date()
    ) -> AttentionProjection {
        let readyActions = actions.filter { !$0.isMaybe }
        let maybeActions = actions.filter(\.isMaybe)
        let draftedConversations = Set(readyActions.compactMap { action -> String? in
            guard action.kindEnum == .reply || action.kindEnum == .ack else { return nil }
            return "\(action.service)|\(action.conversationId)"
        })
        let visibleOwed = owedReplies.filter {
            !draftedConversations.contains("\($0.service)|\($0.conversationId)")
        }
        let actItems = ActItemSorter.sort(
            readyActions.map(ActItem.agentAction) + visibleOwed.map(ActItem.owedReply),
            now: now
        ) { service, conversationID in
            contextsByKey["\(service)|\(conversationID)"]
        }
        let sortedMaybe = ActItemSorter.sort(maybeActions.map(ActItem.agentAction), now: now) {
            service, conversationID in contextsByKey["\(service)|\(conversationID)"]
        }.compactMap { item -> AgentAction? in
            guard case .agentAction(let action) = item else { return nil }
            return action
        }
        let sortedCommitments = commitments.sorted { lhs, rhs in
            switch (lhs.dueAt, rhs.dueAt) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.createdAt < rhs.createdAt
            }
        }
        let sortedTasks = tasks.sorted { $0.createdAt < $1.createdAt }

        func cards(for brief: Brief) -> [BriefCard] {
            if let id = brief.id, let cards = cardsByBriefID[id], !cards.isEmpty { return cards }
            return BriefJSON.decodedCached(for: brief)?.cards ?? []
        }

        let latestCards = briefs.max(by: { $0.createdAt < $1.createdAt }).map(cards(for:)) ?? []
        func effectivePriority(for card: BriefCard) -> String {
            AttentionRanker.effectivePriority(
                card.priority,
                context: contextsByKey["\(card.service)|\(card.conversationId)"]
            )
        }
        let latestDigest = DigestAttentionSummary(
            replyCount: latestCards.filter(\.needsReply).count,
            reviewCount: latestCards.filter {
                !$0.needsReply && effectivePriority(for: $0) == "high"
            }.count,
            quietCount: latestCards.filter {
                let priority = effectivePriority(for: $0)
                return !$0.needsReply && priority != "high" && (priority == "low" || $0.collapsed)
            }.count
        )
        let calendar = Calendar.current
        let todayHigh = briefs
            .filter { calendar.isDateInToday($0.createdAt) && $0.archivedAt == nil }
            .reduce(0) { count, brief in
                guard let briefID = brief.id else { return count }
                return count + cards(for: brief).filter { card in
                    effectivePriority(for: card) == "high"
                        && !handledCardKeys.contains("\(briefID):\(card.id)")
                }.count
            }

        return AttentionProjection(
            actItems: actItems,
            readyActions: readyActions,
            maybeActions: sortedMaybe,
            owedRepliesWithoutDrafts: visibleOwed,
            commitments: sortedCommitments,
            tasks: sortedTasks,
            latestDigest: latestDigest,
            todayHighPriorityUnhandledCount: todayHigh
        )
    }
}
