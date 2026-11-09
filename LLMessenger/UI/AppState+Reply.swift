// AppState+Reply.swift
//
// The Reply composer's state seam, and what happens around a send: staging it
// through the existing undo path, Undo, success/failure reporting, and the
// "Couldn't send" state in Act. Nothing here calls adapter.send — the only send
// code stays in AppState+Delegation.swift (stageManualApprove → timer →
// approveReplyAction). This file only creates/edits pending actions and stages them.

import AppKit
import Foundation

extension AppState {

    // MARK: - Opening and closing the composer

    /// Opens the Reply composer for a conversation. `text` (an AI/agent draft) wins
    /// over a draft the user left unsent earlier in this session.
    func openReplyComposer(service: String,
                           conversationId: String,
                           conversationName: String,
                           text: String? = nil,
                           sourceActionID: Int64? = nil,
                           commitmentId: Int64? = nil) {
        let key = "\(service)|\(conversationId)"
        let provided = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initial = provided.isEmpty ? (savedReplyDrafts[key] ?? "") : (text ?? "")
        replyComposer = ReplyComposerRequest(
            service: service,
            conversationId: conversationId,
            conversationName: conversationName,
            isGroup: ConversationKind.isGroup(
                service: service,
                conversationId: conversationId,
                contacts: contactDirectory.contacts,
                recentMessages: composerContextMessages(service: service, conversationId: conversationId, limit: 12)),
            initialText: initial,
            sourceActionID: sourceActionID,
            commitmentId: commitmentId)
    }

    /// Edit an Act draft or a failed send in the composer. Send updates and stages
    /// that same action, so follow-ups keep their commitment link.
    func openComposer(editing action: AgentAction) {
        guard let id = action.id, ServiceCapabilities.sendsMessage(action.kindEnum),
              action.kindEnum != .rsvp else { return }
        openReplyComposer(service: action.service,
                          conversationId: action.conversationId,
                          conversationName: action.conversationName,
                          text: action.replyPayload?.draftText ?? "",
                          sourceActionID: id)
    }

    /// The last few messages of the conversation, oldest first — quiet context
    /// above the editor and the drafting prompt's input.
    func composerContextMessages(service: String, conversationId: String, limit: Int = 3) -> [Message] {
        (try? repository.fetchRecentContextMessages(
            service: service, conversationID: conversationId,
            before: Date().addingTimeInterval(1), limit: limit)) ?? []
    }

    /// Closing never silently loses text: a new reply is kept per conversation for
    /// the session; edits to an existing action are saved into that action.
    func closeReplyComposer(_ request: ReplyComposerRequest, unsentText: String) {
        let trimmed = unsentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = request.sourceActionID {
            if !trimmed.isEmpty, trimmed != request.initialText.trimmingCharacters(in: .whitespacesAndNewlines),
               let action = try? repository.fetchAgentAction(id: id),
               action.statusEnum == .pending || action.statusEnum == .failed {
                try? repository.updateAgentActionPayload(id: id, payload: AgentAction.encodeReplyPayload(unsentText))
                reloadAgentActions()
                showReceipt("Edit saved to the draft for \(request.displayName).")
            }
        } else if trimmed.isEmpty {
            savedReplyDrafts[request.conversationKey] = nil
        } else {
            savedReplyDrafts[request.conversationKey] = unsentText
        }
        if replyComposer?.id == request.id { replyComposer = nil }
    }

    // MARK: - Sending

    /// The composer's Send. Creates (or updates) exactly one pending reply action
    /// holding exactly `text`, then stages it behind the 5-second undo window via
    /// stageManualApprove. Never sends immediately; never creates an action for a
    /// service that cannot send.
    @discardableResult
    func sendFromComposer(_ request: ReplyComposerRequest, text: String) -> ReplyComposerOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        guard request.canSend else { return .failed(ServiceCapabilities.readOnlyMessage(for: request.service)) }

        let actionID: Int64
        do {
            if let sourceID = request.sourceActionID {
                guard let existing = try repository.fetchAgentAction(id: sourceID),
                      existing.service == request.service,
                      existing.conversationId == request.conversationId else {
                    return .failed("That draft is no longer available.")
                }
                if existing.statusEnum == .failed {
                    guard try repository.requeueFailedAgentAction(id: sourceID) else {
                        return .failed("That draft is no longer available.")
                    }
                    dropStaleTimer(for: sourceID)
                } else if existing.statusEnum != .pending {
                    return .failed("That draft is already being sent.")
                }
                try repository.updateAgentActionPayload(id: sourceID, payload: AgentAction.encodeReplyPayload(text))
                actionID = sourceID
            } else {
                let action = AgentAction.userComposed(
                    service: request.service,
                    conversationId: request.conversationId,
                    conversationName: request.displayName,
                    text: text,
                    commitmentId: request.commitmentId)
                guard let id = try repository.insertAgentAction(action) else {
                    return .failed("Couldn't save the reply.")
                }
                actionID = id
            }
        } catch {
            return .failed(friendly(error))
        }

        guard let staged = try? repository.fetchAgentAction(id: actionID) else {
            return .failed("Couldn't save the reply.")
        }
        stageSend(staged)
        guard (try? repository.fetchAgentAction(id: actionID))?.statusEnum == .scheduled else {
            return .failed(lastError ?? "Couldn't start the send.")
        }
        savedReplyDrafts[request.conversationKey] = nil
        sendFailureReasons[actionID] = nil
        if replyComposer?.id == request.id { replyComposer = nil }
        return .staged(actionID: actionID)
    }

    /// Read-only services (WhatsApp): copy the text and open the service's app.
    /// Nothing is created in the database and nothing reports "sent".
    @discardableResult
    func handOffReadOnlyReply(_ request: ReplyComposerRequest, text: String) -> ReplyComposerOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        replyHandOff(text, ServiceDeepLink.url(service: request.service, conversationId: request.conversationId))
        savedReplyDrafts[request.conversationKey] = nil
        if replyComposer?.id == request.id { replyComposer = nil }
        showReceipt("Copied — opening \(request.serviceName). Paste it into the chat to send.")
        return .handedOff
    }

    /// Every user-initiated stage goes through here so its outcome is reported.
    func stageSend(_ action: AgentAction) {
        guard let id = action.id else { return }
        trackedSendIDs.insert(id)
        // Sample (demo) rows count down and settle like real ones but never reach
        // an adapter — see AppState+SampleSend.swift.
        if action.isSample {
            stageSampleSend(action)
            return
        }
        stageManualApprove(action)
    }

    /// Undo a staged send. A reply the user wrote in the composer goes back into
    /// the composer (it never lingers as a queue item); an agent draft returns to
    /// the queue as before.
    func undoStagedSend(_ action: AgentAction) {
        guard let id = action.id else { return }
        undoAutoSend(action)
        trackedSendIDs.remove(id)
        recordUndo()
        guard action.isUserComposed,
              let current = try? repository.fetchAgentAction(id: id),
              current.statusEnum == .pending else { return }
        try? repository.updateAgentActionStatus(id: id, status: .skipped, resolvedAt: Date())
        reloadAgentActions()
        openReplyComposer(service: current.service,
                          conversationId: current.conversationId,
                          conversationName: current.conversationName,
                          text: current.replyPayload?.draftText,
                          commitmentId: current.commitmentId)
    }

    // MARK: - Couldn't send

    func retryFailedSend(_ action: AgentAction) {
        guard let id = action.id else { return }
        do {
            guard try repository.requeueFailedAgentAction(id: id),
                  let pending = try repository.fetchAgentAction(id: id) else {
                reloadAgentActions()
                return
            }
            sendFailureReasons[id] = nil
            dropStaleTimer(for: id)
            stageSend(pending)
        } catch {
            lastError = friendly(error)
        }
    }

    /// A failed action can still have a leftover timer entry (a reload that
    /// re-armed it from a stale snapshot). Its fire would be a no-op — the row is
    /// not scheduled — but it would block stageManualApprove's one-timer guard.
    private func dropStaleTimer(for id: Int64) {
        guard (try? repository.fetchAgentAction(id: id))?.statusEnum != .scheduled else { return }
        armedTimers[id]?.cancel()
        armedTimers[id] = nil
    }

    func dismissFailedSend(_ action: AgentAction) {
        guard let id = action.id else { return }
        try? repository.dismissFailedAgentAction(id: id)
        sendFailureReasons[id] = nil
        reloadAgentActions()
    }

    func failureReason(for action: AgentAction) -> String {
        if let id = action.id, let reason = sendFailureReasons[id], !reason.isEmpty { return reason }
        // After a restart the in-memory reason is gone; the row carries its own.
        return action.failureReason ?? "\(Theme.serviceName(action.service)) didn't accept the message."
    }

    /// Called from reloadAgentActions with tracked sends that left the active queue.
    /// Reports each settled send exactly once.
    func noteSettledSends(_ rows: [AgentAction]) {
        for row in rows {
            guard let id = row.id else { continue }
            switch row.statusEnum {
            case .done:
                trackedSendIDs.remove(id)
                showReceipt(row.isSample
                            ? "This is a sample, so nothing was sent to \(row.conversationName)."
                            : "Sent to \(row.conversationName) · \(Theme.serviceName(row.service))")
            case .failed:
                trackedSendIDs.remove(id)
                // The send path stores its error in lastError just before reloading;
                // the failed row in Act now carries it, so the banner doesn't repeat it.
                // That runs on the main actor with no suspension between the status
                // write and the error, so this read always sees this send's error.
                if let reason = lastError, !reason.isEmpty {
                    sendFailureReasons[id] = reason
                    if let payload = row.payloadRecordingFailure(reason) {
                        try? repository.updateAgentActionPayload(id: id, payload: payload)
                    }
                    lastError = nil
                }
                showReceipt("Couldn't send to \(row.conversationName) · \(Theme.serviceName(row.service))",
                            actionTitle: "Show",
                            tone: .problem) { [weak self] in
                    self?.requestedSection = .act
                }
            case .scheduled, .executing:
                continue
            case .pending, .skipped, .approved:
                trackedSendIDs.remove(id)
            }
        }
    }
}
