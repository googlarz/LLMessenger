// AppState+Briefs.swift
//
// Brief list state: refresh, pagination, open/handled/pin/archive/snooze,
// grouping, and the needs-reply card queries.

import AppKit
import Foundation
import GRDB

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
        let selectedID = selectedBriefID
        let limit = briefFetchLimit
        return Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let fetched = try self.repository.fetchRecentBriefs(limit: limit, including: selectedID)
                let pipelineHealth = try self.repository.fetchBriefPipelineHealth()
                let healthMap = (try? settingsRepo.loadAllServiceHealth()) ?? [:]
                let heldBack = settingsRepo.loadFirewallHeldBack()
                await MainActor.run {
                    self.briefs = fetched
                    self.briefPipelineHealth = pipelineHealth
                    self.serviceHealthMap = healthMap
                    self.heldBackCount = heldBack
                    self.recomputeNowState()
                    self.onBriefsChanged?()
                    self.reloadOwedReplies()
                    self.reloadAgentActions()
                    self.reloadCommitments()
                    self.reloadContextSuggestions()
                    self.reloadProductOutcomeStats()
                }
            } catch {
                await MainActor.run { self.lastError = self.friendly(error) }
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
              let json = BriefJSON.decodedCached(for: brief) else { return }
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
        let cal = Calendar.current
        let todayHighUnhandled = briefs
            .filter { cal.isDateInToday($0.createdAt) && $0.archivedAt == nil }
            .contains { brief in
                guard let json = BriefJSON.decodedCached(for: brief)
                else { return false }
                return json.cards.contains { card in
                    card.priority == "high" &&
                    !isCardHandled(briefID: brief.id ?? -1, cardID: card.id)
                }
            }
        nowNeedsAttention = todayHighUnhandled
    }
}
