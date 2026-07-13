// AppState+Commitments.swift
//
// P3 Commitments: reload, fulfil, drop, resolve-on-action, follow-up drafts,
// and product outcome stats.

import AppKit
import Foundation
import GRDB

extension AppState {
    // MARK: - P3 Commitments

    func reloadCommitments() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let open = (try? self.repository.fetchOpenCommitments()) ?? []
            await MainActor.run {
                self.commitments = open
                self.commitmentsCount = open.count
                self.reloadProductOutcomeStats()
                self.onBriefsChanged?()
            }
        }
    }

    func reloadProductOutcomeStats() {
        let briefs = self.briefs
        let cardsByBriefID = self.briefCardsByBriefID
        let handled = self.handledCardKeys
        let openCommitments = self.commitmentsCount
        let heldBack = self.heldBackCount
        let database = self.database
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-7 * 86400)
            let audits = (try? await database.dbQueue.read { db in
                try ActionAuditRecord
                    .filter(Column("createdAt") >= cutoff)
                    .fetchAll(db)
            }) ?? []
            let stats = ProductOutcomeStats.lastSevenDays(
                briefs: briefs,
                cardsByBriefID: cardsByBriefID,
                handledCardKeys: handled,
                auditRows: audits,
                openCommitmentCount: openCommitments,
                heldBackCount: heldBack
            )
            await MainActor.run {
                self.productOutcomeStats = stats
            }
        }
    }

    func markCommitmentFulfilled(_ commitment: Commitment) {
        guard let id = commitment.id else { return }
        do {
            try repository.updateCommitmentStatus(id: id, status: .fulfilled)
            reloadCommitments()
        } catch {
            lastError = friendly(error)
        }
    }

    func dropCommitment(_ commitment: Commitment) {
        guard let id = commitment.id else { return }
        do {
            try repository.updateCommitmentStatus(id: id, status: .dropped)
            reloadCommitments()
        } catch {
            lastError = friendly(error)
        }
    }

    /// When a follow_up action is sent, resolve the commitment it was generated for so the
    /// agent stops re-proposing the same nudge every tick. `i_owe` → fulfilled (you delivered
    /// it); `they_owe` → push the due date out so we don't immediately re-chase. No-op for
    /// actions without a commitmentId. Without this, the action goes `.done`, the open
    /// commitment is still due, and the next cycle queues another follow-up.
    func resolveCommitmentForCompletedAction(_ action: AgentAction) {
        guard let cid = action.commitmentId,
              let commitment = try? repository.fetchCommitment(id: cid) else { return }
        do {
            switch commitment.directionEnum {
            case .iOwe:
                try repository.updateCommitmentStatus(id: cid, status: .fulfilled)
            case .theyOwe, .none:
                let next = Date().addingTimeInterval(AgentEngine.staleCommitmentDays * 86400)
                try repository.bumpCommitmentDue(id: cid, to: next)
            }
            reloadCommitments()
        } catch {
            lastError = friendly(error)
        }
    }

    /// Proposes a follow_up for a due commitment on demand (the "Draft follow-up"
    /// button) and surfaces it in the Act queue. Reuses the engine's pure builder.
    func draftFollowUp(for commitment: Commitment) {
        guard let action = AgentEngine.followUpAction(for: commitment) else { return }
        do {
            try repository.insertAgentAction(action)
            reloadAgentActions()
        } catch {
            lastError = friendly(error)
        }
    }
}
