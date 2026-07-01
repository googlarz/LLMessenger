// AppState+Context.swift
//
// Conversation context, suggestions, and priority corrections.

import AppKit
import Foundation
import GRDB

extension AppState {
    // MARK: - Conversation Context

    func saveConversationContext(service: String, conversationId: String, label: String, priorityHint: String) {
        var ctx = (try? repository.fetchConversationContext(service: service, conversationId: conversationId))
            ?? ConversationContext(
                service: service,
                conversationId: conversationId,
                label: label,
                priorityHint: priorityHint,
                updatedAt: Date()
            )
        ctx.label = label
        ctx.priorityHint = priorityHint
        ctx.updatedAt = Date()
        do {
            try repository.upsertConversationContext(ctx)
            mergeConversationContexts([ctx])
        } catch {
            lastError = friendly(error)
        }
    }

    func saveConversationPrivacyOverride(service: String, conversationId: String, privacyOverride: String?) {
        var ctx = (try? repository.fetchConversationContext(service: service, conversationId: conversationId))
            ?? ConversationContext(
                service: service,
                conversationId: conversationId,
                label: "",
                priorityHint: "auto",
                updatedAt: Date()
            )
        ctx.privacyOverride = privacyOverride
        ctx.updatedAt = Date()
        do {
            try repository.upsertConversationContext(ctx)
            mergeConversationContexts([ctx])
        } catch {
            lastError = friendly(error)
        }
    }

    func restoreConversationContext(_ previous: ConversationContext?, service: String, conversationId: String) {
        do {
            if let previous {
                try repository.upsertConversationContext(previous)
                mergeConversationContexts([previous])
            } else {
                try repository.deleteConversationContext(service: service, conversationId: conversationId)
                conversationContextsByKey.removeValue(forKey: conversationContextKey(service: service, conversationId: conversationId))
            }
            reloadOwedReplies()
            reloadAgentActions()
            productLoveMetrics = ProductLoveMetricStore.recordUndo()
        } catch {
            lastError = friendly(error)
        }
    }

    func recordQuietedThread() {
        productLoveMetrics = ProductLoveMetricStore.recordQuietedThread()
        reloadProductOutcomeStats()
    }

    func recordDraftCreated() {
        productLoveMetrics = ProductLoveMetricStore.recordDraftCreated()
    }

    func recordUndo() {
        productLoveMetrics = ProductLoveMetricStore.recordUndo()
    }

    func conversationContextKey(service: String, conversationId: String) -> String {
        "\(service)|\(conversationId)"
    }

    func cachedConversationContext(service: String, conversationId: String) -> ConversationContext? {
        conversationContextsByKey[conversationContextKey(service: service, conversationId: conversationId)]
    }

    func mergeConversationContexts(_ contexts: [ConversationContext]) {
        guard !contexts.isEmpty else { return }
        for context in contexts {
            conversationContextsByKey[conversationContextKey(service: context.service, conversationId: context.conversationId)] = context
        }
    }

    func fetchConversationContext(service: String, conversationId: String) -> ConversationContext? {
        if let cached = cachedConversationContext(service: service, conversationId: conversationId) {
            return cached
        }
        guard let fetched = try? repository.fetchConversationContext(service: service, conversationId: conversationId) else {
            return nil
        }
        mergeConversationContexts([fetched])
        return fetched
    }

    // MARK: - Priority Corrections

    func savePriorityCorrection(service: String, conversationId: String, headline: String, llmPriority: String, userPriority: String) {
        let correction = PriorityCorrection(
            id: nil,
            service: service,
            conversationId: conversationId,
            cardHeadline: headline,
            llmPriority: llmPriority,
            userPriority: userPriority,
            createdAt: Date()
        )
        do {
            try repository.insertPriorityCorrection(correction)
            ContextLearning.applyCorrection(
                db: repository,
                service: service,
                conversationId: conversationId,
                from: llmPriority,
                to: userPriority,
                cardHeadline: headline
            )
            productLoveMetrics = ProductLoveMetricStore.recordPriorityCorrection()
            if userPriority == "low" {
                productLoveMetrics = ProductLoveMetricStore.recordQuietedThread()
            }
            reloadProductOutcomeStats()
        } catch {
            lastError = friendly(error)
        }
    }
}
