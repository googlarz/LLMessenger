// AppState+Commands.swift
//
// User receipts (undo toasts), card handling, and first-week guide state.

import AppKit
import Foundation
import GRDB

extension AppState {
    /// Marks the matching brief card handled if a pending brief surfaces this conversation.
    func markCardHandledForConversation(service: String, conversationId: String) {
        for brief in briefs {
            guard let briefID = brief.id,
                  let json = briefJSON(for: brief) else { continue }
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
        productLoveMetrics = ProductLoveMetricStore.dismissFirstWeekGuide(defaults: defaults)
        showReceipt("First-week guide hidden.")
    }

    func acknowledgeFirstRealDigest() {
        productLoveMetrics = ProductLoveMetricStore.acknowledgeFirstRealDigest(defaults: defaults)
    }

    func showReceipt(_ text: String,
                     actionTitle: String? = nil,
                     tone: UserReceipt.Tone = .done,
                     action: (() -> Void)? = nil) {
        let receipt = UserReceipt(text: text, actionTitle: actionTitle, tone: tone, action: action)
        userReceipt = receipt
        // Every toast is spoken from here, so a new toast cannot forget to be.
        A11y.announce(receipt.spokenText, urgent: tone == .problem || actionTitle != nil)
    }

    func clearReceipt() {
        userReceipt = nil
    }
}
