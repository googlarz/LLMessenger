// LLMessenger/UI/Act/ActQueueRules.swift
//
// The Act queue's decisions, kept out of the view so they are unit-testable:
// which section a row belongs to, when the user is "all caught up", and what
// ⌘Return does for the selected row.

import Foundation

enum ActQueueSection: String, CaseIterable {
    case decision
    case ready
    case older

    var title: String {
        switch self {
        case .decision: return "Needs your decision"
        case .ready: return "Ready to send"
        case .older: return "Older"
        }
    }

    /// One plain line next to the header so the section explains itself.
    var caption: String {
        switch self {
        case .decision: return "Someone is waiting, or a draft needs a closer look"
        case .ready: return "Nothing sends until you press Send"
        case .older: return "Still open after two days or more"
        }
    }
}

/// What ⌘Return does. It always means "the selected row's primary button" —
/// and the selected row's primary button shows the ⌘↩ hint.
enum ActCommandReturn: Equatable {
    /// Nothing is selected: nothing happens.
    case none
    /// Stage the send behind the 5-second undo window.
    case stage(AgentAction)
    /// A "maybe" or high-risk draft: ask before staging.
    case confirm(AgentAction)
    /// Open the Reply composer (owed replies, external-agent proposals).
    case compose(ActItem)
    /// The row is already counting down.
    case alreadySending

    static func == (lhs: ActCommandReturn, rhs: ActCommandReturn) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.alreadySending, .alreadySending): return true
        case let (.stage(a), .stage(b)), let (.confirm(a), .confirm(b)): return a.id == b.id
        case let (.compose(a), .compose(b)): return a.id == b.id
        default: return false
        }
    }
}

enum ActQueueRules {
    static func section(for item: ActItem, now: Date = Date()) -> ActQueueSection {
        if item.isStale(now: now) { return .older }
        switch item {
        case .agentAction(let action):
            return needsDecision(action) ? .decision : .ready
        case .owedReply:
            // No draft exists yet — the user decides what (or whether) to say.
            return .decision
        }
    }

    /// Maybe, high-risk, or written by another app: the user looks before it goes.
    static func needsDecision(_ action: AgentAction) -> Bool {
        action.isMaybe || action.riskEnum == .high || action.isExternalProposal
    }

    /// External-agent proposals never send from the row: their primary button opens
    /// the composer, so muscle memory can't approve text another app wrote.
    static func sendsFromRow(_ action: AgentAction) -> Bool {
        !action.isExternalProposal
    }

    static func commandReturn(for selected: ActItem?) -> ActCommandReturn {
        guard let selected else { return .none }
        switch selected {
        case .owedReply:
            return .compose(selected)
        case .agentAction(let action):
            if action.statusEnum == .scheduled { return .alreadySending }
            if !sendsFromRow(action) { return .compose(selected) }
            return needsDecision(action) ? .confirm(action) : .stage(action)
        }
    }

    // MARK: Selection — by id, never by position

    /// J/K. With nothing selected (start, or right after a send/skip), the first
    /// press selects the row at the anchor — where the user just was.
    static func moveSelection(from selectedID: String?, anchor: Int, by delta: Int, in items: [ActItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let next: Int
        if let selectedID, let current = items.firstIndex(where: { $0.id == selectedID }) {
            next = current + delta
        } else {
            next = delta > 0 ? anchor : anchor - 1
        }
        return items[max(0, min(items.count - 1, next))].id
    }

    /// When the queue changes, the selection survives only if its row is still
    /// there — it never slides onto a neighbour the user hasn't looked at.
    static func retainedSelection(_ selectedID: String?, in ids: [String]) -> String? {
        guard let selectedID, ids.contains(selectedID) else { return nil }
        return selectedID
    }

    /// "You're all caught up": nothing failed, nothing needs a decision, nothing is
    /// ready or counting down. Older items, promises and "waiting on others" may
    /// still be listed below — they don't need anything from you right now.
    static func isCaughtUp(items: [ActItem], failedSends: [AgentAction], now: Date = Date()) -> Bool {
        guard failedSends.isEmpty else { return false }
        return !items.contains { section(for: $0, now: now) != .older }
    }
}
