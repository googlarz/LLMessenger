// AppState+SampleSend.swift
//
// Sending a sample (demo) draft. It looks like a real send to the person trying
// the app — the row counts down, Undo works, then the row leaves Act — but no
// adapter is ever involved.
//
// Why no real adapter can be reached:
//  1. `stageSend`, the one funnel for every user-initiated send (row button,
//     ⌘Return, batch bar, Reply composer), sends a sample row here instead of to
//     `stageManualApprove`. This file never reads `adapters` and never calls send.
//  2. Demo mode holds no adapters at all (`detachAdaptersForDemo`, and
//     `registerAdapter` skips registration while the demo is active), so even the
//     sacred timer path would end in "not connected" for a sample row.
//  3. Sample drafts are never low risk and never delegatable, so neither
//     `batchApproveLowRisk` nor `AgentDelegation` ever picks one up.
// Nothing here changes the sacred send path (AppState+Delegation.swift).

import Foundation

extension AgentAction {
    /// A row the demo seeder wrote (or one the user composed against a sample
    /// conversation). Real conversation ids never start with the sample prefix.
    var isSample: Bool { DemoSeeder.isSampleConversation(conversationId) }
}

extension AppState {

    /// The countdown a sample send shows before the row leaves Act. Same as a real
    /// manual send; a variable only so tests don't wait five seconds.
    static var sampleSendWindow: TimeInterval = AgentAction.manualApproveUndoWindow

    /// Arms the same visible "sending in 5s, Undo" state a real send has, but the
    /// timer it starts only marks the row done. Undo cancels it through the usual
    /// `undoAutoSend`, which cancels `armedTimers[id]`.
    func stageSampleSend(_ action: AgentAction) {
        guard let id = action.id, armedTimers[id] == nil else { return }
        guard let current = try? repository.fetchAgentAction(id: id),
              current.isSample, current.statusEnum == .pending else {
            reloadAgentActions()
            return
        }
        let window = Self.sampleSendWindow
        do {
            guard try repository.armAgentActionForAutoSend(
                id: id,
                scheduledAt: Date().addingTimeInterval(window),
                kind: .manual,
                undoWindow: window) else {
                reloadAgentActions()
                return
            }
        } catch {
            lastError = friendly(error)
            return
        }
        // Registered before the first reload so reconcileScheduledActions sees a
        // timer for this row and never arms the real fire path for it.
        armedTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, window)))
            guard !Task.isCancelled else { return }
            await self?.finishSampleSend(actionID: id)
        }
        reloadAgentActions()
        A11y.announce("Sending \(action.conversationName) reply in 5 seconds. Command Z to cancel.", urgent: true)
    }

    /// The countdown ended: the sample row is marked done. Nothing is sent.
    func finishSampleSend(actionID id: Int64) async {
        armedTimers[id] = nil
        guard let row = try? repository.fetchAgentAction(id: id),
              row.isSample, row.statusEnum == .scheduled else {
            reloadAgentActions()
            return
        }
        try? repository.updateAgentActionStatus(id: id, status: .done, resolvedAt: Date())
        reloadAgentActions()
    }

    /// Demo mode is a sandbox with no live connections: drop every adapter so
    /// nothing in the sample world can reach a real service.
    func detachAdaptersForDemo() {
        for adapter in adapters.values { adapter.stop() }
        adapters.removeAll()
    }
}
