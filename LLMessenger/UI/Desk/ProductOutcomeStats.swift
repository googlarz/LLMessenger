import Foundation

struct ProductOutcomeStats: Equatable {
    var digestCount: Int
    var threadsSummarized: Int
    var sourceBackedCardCount: Int
    var replyNeededCount: Int
    var quietThreadCount: Int
    var handledCount: Int
    var queuedSendCount: Int
    var autoSentCount: Int
    var auditCount: Int
    var openCommitmentCount: Int
    var heldBackCount: Int

    var totalResolved: Int { handledCount + queuedSendCount + autoSentCount }
    var hasSignal: Bool {
        digestCount > 0 || threadsSummarized > 0 || totalResolved > 0 || quietThreadCount > 0 || heldBackCount > 0
    }

    var reassuranceLine: String {
        if totalResolved > 0 {
            return "\(totalResolved) handled, \(quietThreadCount) quieted, \(heldBackCount) held back."
        }
        if replyNeededCount > 0 {
            return "\(replyNeededCount) reply-needed \(replyNeededCount == 1 ? "thread" : "threads") found across \(digestCount) \(digestCount == 1 ? "digest" : "digests")."
        }
        if quietThreadCount > 0 || heldBackCount > 0 {
            return "\(quietThreadCount) quiet \(quietThreadCount == 1 ? "thread" : "threads"), \(heldBackCount) held back."
        }
        if threadsSummarized > 0 {
            return "\(threadsSummarized) \(threadsSummarized == 1 ? "thread" : "threads") summarized. Nothing tracked is waiting."
        }
        return "Connect services or explore sample messages to see what LLMessenger saves you."
    }

    static let empty = ProductOutcomeStats(
        digestCount: 0,
        threadsSummarized: 0,
        sourceBackedCardCount: 0,
        replyNeededCount: 0,
        quietThreadCount: 0,
        handledCount: 0,
        queuedSendCount: 0,
        autoSentCount: 0,
        auditCount: 0,
        openCommitmentCount: 0,
        heldBackCount: 0
    )

    static func lastSevenDays(
        briefs: [Brief],
        handledCardKeys: Set<String>,
        auditRows: [ActionAuditRecord],
        openCommitmentCount: Int,
        heldBackCount: Int,
        now: Date = Date()
    ) -> ProductOutcomeStats {
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let recentBriefs = briefs.filter { $0.createdAt >= cutoff }
        let recentBriefIDs = Set(recentBriefs.compactMap(\.id))
        var threads = 0
        var sourced = 0
        var reply = 0
        var quiet = 0

        for brief in recentBriefs {
            guard let json = BriefJSON.decodeLenient(from: brief.openingSummary) else { continue }
            threads += json.cards.count
            sourced += json.cards.filter { !$0.sourceMessageIds.isEmpty }.count
            reply += json.cards.filter(\.needsReply).count
            quiet += json.cards.filter { !$0.needsReply && ($0.priority == "low" || $0.collapsed) }.count
        }

        let handled = handledCardKeys.filter { key in
            guard let first = key.split(separator: ":", maxSplits: 1).first,
                  let id = Int64(first) else { return false }
            return recentBriefIDs.contains(id)
        }.count

        let recentAudits = auditRows.filter { $0.createdAt >= cutoff }
        return ProductOutcomeStats(
            digestCount: recentBriefs.count,
            threadsSummarized: threads,
            sourceBackedCardCount: sourced,
            replyNeededCount: reply,
            quietThreadCount: quiet,
            handledCount: handled,
            queuedSendCount: recentAudits.filter { $0.trigger == "approved" }.count,
            autoSentCount: recentAudits.filter { $0.trigger == "delegated" }.count,
            auditCount: recentAudits.count,
            openCommitmentCount: openCommitmentCount,
            heldBackCount: heldBackCount
        )
    }
}
