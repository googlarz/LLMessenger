// AppState+Briefs.swift
//
// Brief list state: refresh, pagination, open/handled/pin/archive/snooze,
// grouping, and the needs-reply card queries.

import AppKit
import Foundation
import GRDB

private struct BriefRefreshSnapshot: @unchecked Sendable {
    let briefs: [Brief]
    let cardsByBriefID: [Int64: [BriefCard]]
    let pipelineHealth: BriefPipelineHealth
    let serviceHealth: [String: ServiceHealth]
    let heldBackCount: Int
}

extension AppState {
    /// Returns the reload task so callers that need deterministic sequencing
    /// (tests, chained UI updates) can await it; UI call sites discard it.
    @discardableResult
    func markAsOpen(briefID: Int64) -> Task<Void, Never> {
        lastError = nil
        do {
            try repository.markAsOpen(briefID: briefID)
            InstrumentationManager.shared.track(event: .briefOpened, metadata: ["briefID": briefID])
            productLoveMetrics = ProductLoveMetricStore.recordOpenedDigest()
            return refreshBriefs()
        } catch {
            lastError = friendly(error)
            return Task {}
        }
    }

    @discardableResult
    func refreshBriefs() -> Task<Void, Never> {
        let settingsRepo = makeSettingsRepository()
        let repository = repository
        let selectedID = selectedBriefID
        let limit = briefFetchLimit
        return Task { @MainActor [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    let briefs = try repository.fetchRecentBriefs(limit: limit, including: selectedID)
                    return BriefRefreshSnapshot(
                        briefs: briefs,
                        cardsByBriefID: try repository.fetchBriefCards(briefIDs: briefs.compactMap(\.id)),
                        pipelineHealth: try repository.fetchBriefPipelineHealth(),
                        serviceHealth: (try? settingsRepo.loadAllServiceHealth()) ?? [:],
                        heldBackCount: settingsRepo.loadFirewallHeldBack()
                    )
                }.value
                guard let self else { return }
                self.briefCardsByBriefID = snapshot.cardsByBriefID
                self.briefs = snapshot.briefs
                self.briefPipelineHealth = snapshot.pipelineHealth
                self.serviceHealthMap = snapshot.serviceHealth
                self.heldBackCount = snapshot.heldBackCount
                self.recomputeNowState()
                self.onBriefsChanged?()
                self.reloadOwedReplies()
                self.reloadAgentActions()
                self.reloadCommitments()
                self.reloadContextSuggestions()
                self.reloadProductOutcomeStats()
            } catch {
                guard let self else { return }
                self.lastError = self.friendly(error)
            }
        }
    }

    @discardableResult
    func retryBlockedBriefJobs() -> Int {
        do {
            let count = try repository.retryDeadLetterBriefJobs()
            briefPipelineHealth = .healthy
            lastError = nil
            if count > 0 {
                onRequestRefresh?()
            } else {
                refreshBriefs()
            }
            return count
        } catch {
            lastError = friendly(error)
            return 0
        }
    }

    @discardableResult
    func loadOlderBriefs() -> Task<Void, Never> {
        briefFetchLimit += 500
        return refreshBriefs()
    }

    func reloadOwedReplies() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let contexts = try self.repository.fetchAllConversationContexts()
                let owed = try OwedReplyDeriver().derive(db: self.database, contexts: contexts)
                await MainActor.run {
                    self.mergeConversationContexts(contexts)
                    self.owedReplies = owed
                    self.owedCount = owed.count
                    self.onBriefsChanged?()
                }
            } catch {
                await MainActor.run { self.lastError = self.friendly(error) }
            }
        }
    }

    func reloadAgentActions() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let actions = (try? self.repository.fetchPendingAgentActions()) ?? []
            let pairs = actions.map { (service: $0.service, conversationId: $0.conversationId) }
            let contexts = (try? self.repository.fetchConversationContexts(for: pairs)) ?? []
            let delegated = contexts.contains { !$0.delegationKinds.isEmpty }
            await MainActor.run {
                self.agentActions = actions
                self.mergeConversationContexts(contexts)
                // "Maybe" proposals are the user's call, not part of the ready-to-send count.
                self.actionsReadyCount = actions.filter { !$0.isMaybe }.count
                self.hasDelegatedLanes = delegated
                self.reloadProductOutcomeStats()
                self.onBriefsChanged?()
                let changedDuringRecovery = self.reconcileScheduledActions()
                if !changedDuringRecovery {
                    self.evaluateDelegation()
                }
            }
        }
    }
    func markCardHandled(briefID: Int64, cardID: String) {
        let inserted = handledCardKeys.insert("\(briefID):\(cardID)").inserted
        UserDefaults.standard.set(Array(handledCardKeys), forKey: "handledCardKeys")
        if inserted {
            productLoveMetrics = ProductLoveMetricStore.recordHandledCard()
            reloadProductOutcomeStats()
            showReceipt("Card marked done.", actionTitle: "Undo") { [weak self] in
                guard let self else { return }
                self.unmarkCardHandled(briefID: briefID, cardID: cardID)
                self.productLoveMetrics = ProductLoveMetricStore.recordUndo()
                self.reloadProductOutcomeStats()
            }
        }
    }

    func unmarkCardHandled(briefID: Int64, cardID: String) {
        handledCardKeys.remove("\(briefID):\(cardID)")
        UserDefaults.standard.set(Array(handledCardKeys), forKey: "handledCardKeys")
    }

    func isCardHandled(briefID: Int64, cardID: String) -> Bool {
        handledCardKeys.contains("\(briefID):\(cardID)")
    }

    func markAllHandled(briefID: Int64) {
        guard let brief = briefs.first(where: { $0.id == briefID }),
              let json = briefJSON(for: brief) else { return }
        for card in json.cards {
            markCardHandled(briefID: briefID, cardID: card.id)
        }
    }

    func setPinnedBrief(briefID: Int64, pinned: Bool) {
        do {
            try repository.setPinned(briefID: briefID, pinned: pinned)
            refreshBriefs()
        } catch {
            lastError = friendly(error)
        }
    }

    var pinnedBriefs: [Brief] {
        briefs.filter { $0.pinned && $0.archivedAt == nil }.sorted { $0.createdAt > $1.createdAt }
    }

    var archivedBriefs: [Brief] {
        briefs.filter { $0.archivedAt != nil }.sorted { $0.createdAt > $1.createdAt }
    }

    func briefGroups(from: Date? = nil, to: Date? = nil) -> [BriefListGroup] {
        let now = Date()
        let filtered = briefs.filter { brief in
            guard brief.archivedAt == nil else { return false }
            if let snoozedUntil = brief.snoozedUntil, snoozedUntil > now { return false }
            if let from = from, brief.createdAt < from { return false }
            if let to = to, brief.createdAt > to { return false }
            return true
        }
        return BriefListGrouper.group(filtered)
    }

    func archiveBrief(_ briefID: Int64) {
        do {
            try repository.setArchived(briefID: briefID, archivedAt: Date())
            refreshBriefs()
            showReceipt("Digest filed away.", actionTitle: "Undo") { [weak self] in
                guard let self else { return }
                self.unarchiveBrief(briefID)
                self.productLoveMetrics = ProductLoveMetricStore.recordUndo()
            }
        } catch {
            lastError = friendly(error)
        }
    }

    func unarchiveBrief(_ briefID: Int64) {
        do {
            try repository.setArchived(briefID: briefID, archivedAt: nil)
            refreshBriefs()
        } catch {
            lastError = friendly(error)
        }
    }

    func snoozeBrief(id briefID: Int64, until date: Date) {
        do {
            try repository.setSnoozed(briefID: briefID, snoozedUntil: date)
            refreshBriefs()
            showReceipt("Digest snoozed.", actionTitle: "Undo") { [weak self] in
                guard let self else { return }
                do {
                    try self.repository.setSnoozed(briefID: briefID, snoozedUntil: nil)
                    self.refreshBriefs()
                    self.productLoveMetrics = ProductLoveMetricStore.recordUndo()
                } catch {
                    self.lastError = self.friendly(error)
                }
            }
        } catch {
            lastError = friendly(error)
        }
    }

    func recomputeNowState() {
        recomputeAttentionProjection()
    }

    func recomputeAttentionProjection(now: Date = Date()) {
        attentionProjection = AttentionProjection.build(
            briefs: briefs,
            cardsByBriefID: briefCardsByBriefID,
            handledCardKeys: handledCardKeys,
            actions: agentActions,
            owedReplies: owedReplies,
            commitments: commitments,
            tasks: tasks,
            contextsByKey: conversationContextsByKey,
            now: now
        )
        nowNeedsAttention = attentionProjection.todayHighPriorityUnhandledCount > 0
    }
}
