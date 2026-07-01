// AppState+Delegation.swift
//
// P2 Scoped delegation (gated auto-send). SACRED PATH — moved verbatim from
// AppState.swift in the file split; do not edit logic here without the full
// delegation test suite and an injection re-test.

import AppKit
import Foundation
import GRDB

extension AppState {
    // MARK: - P2 Scoped delegation (gated auto-send)

    /// Seconds a delegated auto-send stays armed before firing — the Undo window.
    static let autoSendUndoWindow: TimeInterval = AgentAction.delegatedUndoWindow

    // NOTE: this section's stored state (`armedTimers`, `armedAutoSendCount`,
    // `calendarActor`, `calendarAccessOverrideForTesting`) lives in AppState.swift —
    // Swift extensions cannot hold stored properties.

    /// For every pending action, ask AgentDelegation whether it may auto-send. If so,
    /// arm it with a 30s Undo window instead of sending immediately. This is the ONLY
    /// path that arms an auto-send; the decision reads only structured action fields
    /// and user-set context — never message content.
    func evaluateDelegation() {
        // A "maybe" is the user's call and must never auto-send. (Belt-and-suspenders: maybe is
        // only set on reply actions today, which are non-delegatable anyway.)
        for action in agentActions where action.statusEnum == .pending && !action.isMaybe {
            guard let id = action.id, armedTimers[id] == nil else { continue }
            let ctx = fetchConversationContext(service: action.service, conversationId: action.conversationId)
            let known = isKnownRecipient(service: action.service, conversationId: action.conversationId)
            let decision = AgentDelegation.decide(
                action: action,
                context: ctx,
                isKnownRecipient: known,
                clientIsLocal: llmClient.isLocal)
            guard decision.autoSend else { continue }
            armAutoSend(action)
        }
        refreshArmedCount()
    }

    private func armAutoSend(_ action: AgentAction) {
        guard let id = action.id else { return }
        guard armedTimers[id] == nil else { return }
        let fireAt = Date().addingTimeInterval(Self.autoSendUndoWindow)
        do {
            let armed = try repository.armAgentActionForAutoSend(
                id: id,
                scheduledAt: fireAt,
                kind: .delegated,
                undoWindow: Self.autoSendUndoWindow)
            guard armed else {
                reloadAgentActions()
                return
            }
        } catch {
            lastError = friendly(error)
            return
        }
        NotificationManager.postAutoSendArmedNotification(
            conversationName: action.conversationName,
            actionTitle: action.title,
            actionID: id
        )
        armScheduledTimer(actionID: id, kind: .delegated, delay: Self.autoSendUndoWindow)
        reloadAgentActions()
    }

    /// User tapped Undo within the window: cancel the timer and revert to pending
    /// (manual approval required). No send happens; no "delegated" audit row is written.
    func undoAutoSend(_ action: AgentAction) {
        guard let id = action.id else { return }
        armedTimers[id]?.cancel()
        armedTimers[id] = nil
        try? repository.disarmAgentAction(id: id)
        reloadAgentActions()
    }

    @discardableResult
    func reconcileScheduledActions() -> Bool {
        var changed = false
        for action in agentActions where action.statusEnum == .scheduled {
            guard let id = action.id,
                  let kind = action.scheduledKindEnum,
                  let fireAt = action.scheduledAt else {
                if let id = action.id {
                    try? repository.disarmAgentAction(id: id)
                    changed = true
                }
                continue
            }
            guard armedTimers[id] == nil else { continue }
            let remaining = fireAt.timeIntervalSinceNow
            if remaining <= 0 {
                // If the app was not running for the Undo window, prefer safety: put
                // the proposal back in the queue instead of sending immediately.
                try? repository.disarmAgentAction(id: id)
                changed = true
                continue
            }
            armScheduledTimer(actionID: id, kind: kind, delay: remaining)
        }
        refreshArmedCount()
        if changed {
            reloadAgentActions()
        }
        return changed
    }

    private func armScheduledTimer(actionID id: Int64, kind: AgentActionScheduleKind, delay: TimeInterval) {
        guard armedTimers[id] == nil else { return }
        armedTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            switch kind {
            case .delegated:
                await self?.fireDelegatedSend(actionID: id)
            case .manual:
                await self?.fireManualApprovedSend(actionID: id)
            }
        }
    }

    /// Fires after the Undo window elapses. Re-reads the row and re-checks it is still
    /// scheduled before sending (defends against a race with Undo). Sends via the SAME
    /// adapter.send path as approveAction and writes a "delegated" audit row.
    // Internal (not private) so the delegation pipeline integration test can drive the
    // fire path directly instead of waiting out the real 30s undo timer.
    func fireDelegatedSend(actionID: Int64) async {
        armedTimers[actionID] = nil
        guard let scheduledAction = try? repository.fetchAgentAction(id: actionID),
              scheduledAction.statusEnum == .scheduled,
              scheduledAction.scheduledKindEnum == .delegated else {
            refreshArmedCount()
            return
        }
        guard let adapter = adapters[scheduledAction.service] else {
            try? repository.disarmAgentAction(id: actionID)
            reloadAgentActions()
            return
        }
        // Re-validate immediately before sending. The kill switch, delegation settings, or
        // privacy override may have changed during the 30s undo window — re-running the
        // single decide() gate ensures nothing fires that is no longer authorized. On a
        // failed re-check, revert to pending (manual approval) rather than dropping it.
        let ctx = fetchConversationContext(service: scheduledAction.service, conversationId: scheduledAction.conversationId)
        let known = isKnownRecipient(service: scheduledAction.service, conversationId: scheduledAction.conversationId)
        let decision = AgentDelegation.decide(
            action: scheduledAction, context: ctx, isKnownRecipient: known, clientIsLocal: llmClient.isLocal)
        guard decision.autoSend else {
            try? repository.disarmAgentAction(id: actionID)
            reloadAgentActions()
            return
        }
        do {
            guard try repository.claimScheduledActionForExecution(id: actionID) else {
                refreshArmedCount()
                return
            }
        } catch {
            lastError = friendly(error)
            refreshArmedCount()
            return
        }
        guard let action = try? repository.fetchAgentAction(id: actionID) else {
            refreshArmedCount()
            return
        }
        // Resolve the message text by action kind. An rsvp's payload is a CalendarPayload
        // object, NOT a message — blindly falling back to the raw payload would transmit
        // JSON. This mirrors approveRSVP's replyText resolution.
        let sendText: String
        switch action.kindEnum {
        case .rsvp:
            sendText = action.calendarPayload?.replyText ?? "Yes, that works for me."
        case .ack, .reply, .followUp, .calendarHold, .none:
            sendText = action.replyPayload?.draftText ?? action.payload
        }
        do {
            try await adapter.send(conversationID: action.conversationId, text: sendText)
            try ActionAuditLog.record(
                db: database,
                kind: action.kind,
                service: action.service,
                conversationId: action.conversationId,
                detail: sendText,
                trigger: .delegated)
            try repository.updateAgentActionStatus(id: actionID, status: .done, resolvedAt: Date())
            resolveCommitmentForCompletedAction(action)
            markCardHandledForConversation(service: action.service, conversationId: action.conversationId)
        } catch {
            try? repository.updateAgentActionStatus(id: actionID, status: .failed, resolvedAt: Date())
            lastError = friendly(error)
        }
        reloadAgentActions()
    }

    private func refreshArmedCount() {
        armedAutoSendCount = agentActions.filter { $0.statusEnum == .scheduled }.count
    }

    /// Cancels every armed auto-send (menu bar "Undo all").
    func undoAllAutoSends() {
        for action in agentActions where action.statusEnum == .scheduled {
            undoAutoSend(action)
        }
    }

    /// A recipient is "known" if the conversation already has at least one prior
    /// message (sent or received) — never a brand-new contact.
    private func isKnownRecipient(service: String, conversationId: String) -> Bool {
        ((try? repository.conversationHasMessages(service: service, conversationId: conversationId)) ?? false)
    }

    /// Approves a proposed action. For "reply" this routes through the SAME
    /// confirmed-send path the chat window uses — but it is user-initiated here
    /// (the user tapped Approve), so this is NOT auto-send.
    func approveAction(_ action: AgentAction) {
        guard let id = action.id else { return }
        switch action.kindEnum {
        case .reply, .followUp:
            approveReplyAction(action, id: id)
        case .calendarHold:
            approveCalendarHold(action, id: id)
        case .rsvp:
            approveRSVP(action, id: id)
        case .ack, .none:
            approveReplyAction(action, id: id)
        }
    }

    // 5-second staging window for manual approves. The action transitions to
    // .scheduled and the card shows a countdown + UNDO. After 5s, the row is
    // re-read and claimed before sending.
    // This gives the user a fast "whoops" escape without requiring a separate confirm step.
    private static let manualApproveWindow: TimeInterval = AgentAction.manualApproveUndoWindow

    func stageManualApprove(_ action: AgentAction) {
        guard let id = action.id else { return }
        guard armedTimers[id] == nil else { return }
        guard let current = try? repository.fetchAgentAction(id: id),
              current.statusEnum == .pending else {
            reloadAgentActions()
            return
        }
        let fireAt = Date().addingTimeInterval(Self.manualApproveWindow)
        do {
            let armed = try repository.armAgentActionForAutoSend(
                id: id,
                scheduledAt: fireAt,
                kind: .manual,
                undoWindow: Self.manualApproveWindow)
            guard armed else {
                reloadAgentActions()
                return
            }
        } catch {
            lastError = friendly(error)
            return
        }
        armScheduledTimer(actionID: id, kind: .manual, delay: Self.manualApproveWindow)
        reloadAgentActions()
        // Announce to VoiceOver so the user hears the 5-second undo window.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: NSAccessibility.Notification(rawValue: "AXAnnouncementRequested"),
            userInfo: [
                .announcement: "Sending \(action.conversationName) reply in 5 seconds. Command Z to cancel." as NSString,
                .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber
            ]
        )
    }

    func fireManualApprovedSend(actionID: Int64) async {
        armedTimers[actionID] = nil
        guard let scheduledAction = try? repository.fetchAgentAction(id: actionID),
              scheduledAction.statusEnum == .scheduled,
              scheduledAction.scheduledKindEnum == .manual else {
            refreshArmedCount()
            return
        }
        do {
            guard try repository.claimScheduledActionForExecution(id: actionID) else {
                refreshArmedCount()
                return
            }
        } catch {
            lastError = friendly(error)
            refreshArmedCount()
            return
        }
        guard let action = try? repository.fetchAgentAction(id: actionID) else {
            refreshArmedCount()
            return
        }
        approveAction(action)
    }

    private func approveReplyAction(_ action: AgentAction, id: Int64) {
        guard let draftText = action.replyPayload?.draftText else {
            lastError = "Reply text is missing."
            failIfExecuting(action, id: id)
            return
        }
        guard let adapter = adapters[action.service] else {
            lastError = "\(Theme.serviceName(action.service)) is not connected."
            returnToPendingIfExecuting(action, id: id)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await adapter.send(conversationID: action.conversationId, text: draftText)
                try ActionAuditLog.record(
                    db: self.database,
                    kind: action.kind,
                    service: action.service,
                    conversationId: action.conversationId,
                    detail: draftText,
                    trigger: .approved)
                try self.repository.updateAgentActionStatus(id: id, status: .done, resolvedAt: Date())
                self.resolveCommitmentForCompletedAction(action)
                self.markCardHandledForConversation(service: action.service, conversationId: action.conversationId)
                self.reloadAgentActions()
            } catch {
                try? self.repository.updateAgentActionStatus(id: id, status: .failed, resolvedAt: Date())
                self.lastError = self.friendly(error)
                self.reloadAgentActions()
            }
        }
    }

    private func approveCalendarHold(_ action: AgentAction, id: Int64) {
        guard let payload = action.calendarPayload,
              let start = payload.start, let end = payload.end else {
            lastError = "Calendar event details are missing or invalid."
            failIfExecuting(action, id: id)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.ensureCalendarAccess()
            guard granted else {
                // Leave the action pending so the user can retry after granting access.
                self.lastError = "Calendar access is required to create this event."
                self.returnToPendingIfExecuting(action, id: id)
                return
            }
            do {
                try await self.calendarActor.createEvent(
                    title: payload.title, start: start, end: end, notes: payload.notes)
                try ActionAuditLog.record(
                    db: self.database,
                    kind: action.kind,
                    service: action.service,
                    conversationId: action.conversationId,
                    detail: "Created event: \(payload.title) @ \(payload.startISO)",
                    trigger: .approved)
                try self.repository.updateAgentActionStatus(id: id, status: .done, resolvedAt: Date())
                self.reloadAgentActions()
            } catch {
                self.lastError = self.friendly(error)
                // Leave pending; do not mark failed for an access/save issue the user can fix.
                self.returnToPendingIfExecuting(action, id: id)
            }
        }
    }

    private func approveRSVP(_ action: AgentAction, id: Int64) {
        guard let payload = action.calendarPayload else {
            lastError = "RSVP details are missing."
            failIfExecuting(action, id: id)
            return
        }
        guard let adapter = adapters[action.service] else {
            lastError = "\(Theme.serviceName(action.service)) is not connected."
            returnToPendingIfExecuting(action, id: id)
            return
        }
        let replyText = payload.replyText ?? "Yes, that works for me."
        Task { [weak self] in
            guard let self else { return }
            do {
                try await adapter.send(conversationID: action.conversationId, text: replyText)
                // Best-effort: also hold the slot if access is already granted.
                if let start = payload.start, let end = payload.end,
                   await self.ensureCalendarAccess() {
                    try? await self.calendarActor.createEvent(
                        title: payload.title, start: start, end: end, notes: payload.notes)
                }
                try ActionAuditLog.record(
                    db: self.database,
                    kind: action.kind,
                    service: action.service,
                    conversationId: action.conversationId,
                    detail: replyText,
                    trigger: .approved)
                try self.repository.updateAgentActionStatus(id: id, status: .done, resolvedAt: Date())
                self.markCardHandledForConversation(service: action.service, conversationId: action.conversationId)
                self.reloadAgentActions()
            } catch {
                try? self.repository.updateAgentActionStatus(id: id, status: .failed, resolvedAt: Date())
                self.lastError = self.friendly(error)
                self.reloadAgentActions()
            }
        }
    }

    private func returnToPendingIfExecuting(_ action: AgentAction, id: Int64) {
        guard action.statusEnum == .executing else { return }
        try? repository.updateAgentActionStatus(id: id, status: .pending, resolvedAt: nil)
        reloadAgentActions()
    }

    private func failIfExecuting(_ action: AgentAction, id: Int64) {
        guard action.statusEnum == .executing else { return }
        try? repository.updateAgentActionStatus(id: id, status: .failed, resolvedAt: Date())
        reloadAgentActions()
    }

    /// Returns true if calendar write access is granted, requesting it if undetermined.
    private func ensureCalendarAccess() async -> Bool {
        if let override = calendarAccessOverrideForTesting { return override }
        let status = calendarActor.authorizationStatus()
        if #available(macOS 14.0, *) {
            if status == .fullAccess || status == .writeOnly { return true }
        } else {
            if status == .authorized { return true }
        }
        if status == .notDetermined {
            return await calendarActor.requestAccess()
        }
        return false
    }

    func editAction(_ action: AgentAction, newText: String) {
        guard let id = action.id else { return }
        do {
            try repository.updateAgentActionPayload(id: id, payload: AgentAction.encodeReplyPayload(newText))
            reloadAgentActions()
        } catch {
            lastError = friendly(error)
        }
    }

    func skipAction(_ action: AgentAction) {
        guard let id = action.id else { return }
        do {
            try repository.updateAgentActionStatus(id: id, status: .skipped, resolvedAt: Date())
            reloadAgentActions()
            showReceipt("Skipped suggested action.", actionTitle: "Undo") { [weak self] in
                try? self?.repository.updateAgentActionStatus(id: id, status: .pending, resolvedAt: nil)
                self?.reloadAgentActions()
                self?.recordUndo()
            }
        } catch {
            lastError = friendly(error)
        }
    }

    /// Stages every pending low-risk action behind the same 5-second undo window
    /// as a single manual Approve. Only touches "low" risk rows.
    func batchApproveLowRisk() {
        // Never bulk-approve a "maybe" — it stays the user's individual call.
        for action in agentActions where action.statusEnum == .pending && action.riskEnum == .low && !action.isMaybe {
            stageManualApprove(action)
        }
    }
}
