// AppState+Commands.swift
//
// P5 command execution, user receipts (undo toasts), and first-week guide state.

import AppKit
import Foundation
import GRDB

extension AppState {
    // MARK: - P5 Command execution

    /// Performs an already-classified command against the agent queue and returns a
    /// short, user-facing result line. The classification (free text → CommandIntent)
    /// happens in CommandRouter; this method only maps a known intent to an operation.
    @discardableResult
    func runCommand(_ command: ParsedCommand) async -> String {
        switch command.intent {
        case .catchMeUp:
            await onTriggerAgentCycle?()
            reloadAgentActions()
            reloadCommitments()
            reloadOwedReplies()
            let pending = actionsReadyCount
            let owed = owedCount
            return "Caught up — \(pending) pending action\(pending == 1 ? "" : "s"), \(owed) reply\(owed == 1 ? "" : "ies") owed."

        case .handleEasy:
            let n = agentActions.filter {
                $0.statusEnum == .pending && $0.riskEnum == .low && !$0.isMaybe
            }.count
            batchApproveLowRisk()
            if n == 0 { return "No low-risk actions to approve." }
            return "Staged \(n) low-risk action\(n == 1 ? "" : "s") with 5-second undo."

        case .whatDoIOwe:
            let iOwe = commitments.filter { $0.directionEnum == .iOwe }.count
            let owed = owedCount
            if iOwe == 0 && owed == 0 { return "You're clear — nothing owed." }
            return "You owe \(owed) reply\(owed == 1 ? "" : "ies") and have \(iOwe) open commitment\(iOwe == 1 ? "" : "s")."

        case .draftAllWaiting:
            await onTriggerAgentCycle?()
            reloadAgentActions()
            let replies = agentActions.filter { $0.kindEnum == .reply }.count
            return "Drafted \(replies) repl\(replies == 1 ? "y" : "ies") for review."

        case .unknown:
            return "Sorry — I didn't understand that command."
        }
    }

    /// Marks the matching brief card handled if a pending brief surfaces this conversation.
    func markCardHandledForConversation(service: String, conversationId: String) {
        for brief in briefs {
            guard let briefID = brief.id,
                  let json = BriefJSON.decodeLenient(from: brief.openingSummary) else { continue }
            if let card = json.cards.first(where: { $0.service == service && $0.conversationId == conversationId }) {
                markCardHandled(briefID: briefID, cardID: card.id)
            }
        }
    }

    func reloadContextSuggestions() {
        let engine = contextSuggestionEngine
        let db = database
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let suggestions = (try? await engine.computeContextSuggestions(db: db)) ?? []
            await MainActor.run { self.contextSuggestions = suggestions }
        }
    }

    func acceptContextSuggestion(_ suggestion: ContextSuggestion) {
        let service = suggestion.service
        let conversationId = suggestion.conversationId
        var ctx = (try? repository.fetchConversationContext(service: service, conversationId: conversationId))
            ?? ConversationContext(service: service, conversationId: conversationId,
                                   label: "", priorityHint: "auto", updatedAt: Date())
        if suggestion.kind == "keySender" {
            var senders = ctx.keySendersList
            if !senders.contains(where: { $0.caseInsensitiveCompare(suggestion.subject) == .orderedSame }) {
                senders.append(suggestion.subject)
                ctx.keySendersList = senders
            }
        } else if suggestion.kind == "tone" {
            ctx.tone = "casual, emoji-friendly"
        } else {
            ctx.priorityHint = "high"
        }
        ctx.updatedAt = Date()
        do {
            try repository.upsertConversationContext(ctx)
            mergeConversationContexts([ctx])
        } catch {
            lastError = friendly(error)
        }
        contextSuggestions.removeAll { $0.id == suggestion.id }
        Task { await contextSuggestionEngine.dismissContext(suggestion: suggestion) }
        reloadOwedReplies()
    }

    func dismissContextSuggestion(_ suggestion: ContextSuggestion) {
        contextSuggestions.removeAll { $0.id == suggestion.id }
        Task { await contextSuggestionEngine.dismissContext(suggestion: suggestion) }
    }

    func dismissFirstWeekGuide() {
        productLoveMetrics = ProductLoveMetricStore.dismissFirstWeekGuide()
        showReceipt("First-week guide hidden.")
    }

    func acknowledgeFirstRealDigest() {
        productLoveMetrics = ProductLoveMetricStore.acknowledgeFirstRealDigest()
    }

    func showReceipt(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        userReceipt = UserReceipt(text: text, actionTitle: actionTitle, action: action)
    }

    func clearReceipt() {
        userReceipt = nil
    }
}
