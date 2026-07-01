// LLMessenger/UI/AppState.swift
import Foundation
import AppKit
import GRDB

// MARK: - Shared Value Types

struct ReplyDraft: Identifiable, Equatable {
    let id: UUID
    var text: String
    let serviceID: String
    let conversationID: String
    let senderName: String
    var provenance: String? = nil
}

struct ConversationOption: Identifiable, Equatable {
    let id = UUID()
    let number: Int
    let service: String       // "signal", "telegram", etc.
    let convId: String        // raw conversation ID
    let displayName: String   // "Alice Müller", "Work group"
}

struct UserReceipt: Identifiable {
    let id = UUID()
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?
}

struct ThreadSource: Identifiable, Equatable {
    let id = UUID()
    let service: String
    let conversationID: String
    let sender: String
    let text: String
    let timestamp: Date
}

enum ThreadItem: Identifiable {
    case message(Message)
    case userMessage(id: UUID, text: String)
    case assistantResponse(id: UUID, text: String)
    case assistantResponseWithSources(id: UUID, text: String, sources: [ThreadSource])
    case replyDraft(id: UUID, draft: ReplyDraft)
    case sendConfirmation(id: UUID, draft: ReplyDraft)
    /// Shown when a reply intent targets multiple conversations — user picks one by number.
    case conversationPicker(id: UUID, originalRequest: String, options: [ConversationOption])

    var id: String {
        switch self {
        case .message(let m):                return "msg-\(m.id ?? 0)"
        case .userMessage(let i, _):         return "user-\(i)"
        case .assistantResponse(let i, _):   return "asst-\(i)"
        case .assistantResponseWithSources(let i, _, _): return "asst-src-\(i)"
        case .replyDraft(let i, _):          return "draft-\(i)"
        case .sendConfirmation(let i, _):    return "send-\(i)"
        case .conversationPicker(let i, _, _): return "picker-\(i)"
        }
    }
}

struct BriefListGroup: Identifiable {
    let id: String
    let label: String
    let briefs: [Brief]
}

enum BriefGenerationState: String {
    case cached
    case fetching
    case summarizing
    case partial
    case complete
    case noNewMessages
    case failed
}

// MARK: - BriefListGrouper

struct BriefListGrouper {

    static func group(_ briefs: [Brief], calendar: Calendar = .current) -> [BriefListGroup] {
        let sorted = briefs.sorted { $0.createdAt > $1.createdAt }
        var result: [BriefListGroup] = []
        var seen: [String: Int] = [:]
        for brief in sorted {
            let label = dayLabel(for: brief.createdAt, calendar: calendar)
            if let idx = seen[label] {
                result[idx] = BriefListGroup(
                    id: label,
                    label: result[idx].label,
                    briefs: result[idx].briefs + [brief]
                )
            } else {
                seen[label] = result.count
                result.append(BriefListGroup(id: label, label: label, briefs: [brief]))
            }
        }
        return result
    }

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return mediumDateFormatter.string(from: date)
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    @Published var isDemoTransitioning = false   // true during demo→real morph window
    @Published var briefs: [Brief] = []
    @Published var tasks: [BriefTask] = []
    @Published var selectedBriefID: Int64?
    @Published var serviceHealth: [String: AdapterHealthResult.Status] = [:]
    @Published var serviceHealthMap: [String: ServiceHealth] = [:]
    @Published var nextPollDate: Date?
    @Published var lastError: String?
    @Published var userReceipt: UserReceipt?
    @Published var briefGenerationState: BriefGenerationState = .cached
    /// Keys of cards the user has marked as handled. Format: "\(briefID):\(cardID)".
    /// Persisted to UserDefaults so state survives app restarts.
    /// Number of messages/threads held back (not surfaced in the brief) this round.
    @Published var heldBackCount: Int = 0
    /// True when any high-priority card from today is unhandled.
    @Published var nowNeedsAttention: Bool = false
    /// Conversations where the user owes a reply (derived, not stored).
    @Published var owedReplies: [OwedReply] = []
    @Published var owedCount: Int = 0

    /// Pending agent-proposed actions (the Act queue) and their count.
    @Published var agentActions: [AgentAction] = []
    @Published var actionsReadyCount: Int = 0
    /// True when at least one conversation has delegation configured.
    /// Drives the always-visible kill switch in the menu bar.
    @Published var hasDelegatedLanes: Bool = false

    /// Open commitments (the ledger) and their count.
    @Published var commitments: [Commitment] = []
    @Published var commitmentsCount: Int = 0

    @Published var contextSuggestions: [ContextSuggestion] = []
    private let contextSuggestionEngine = RuleSuggestionEngine()
    @Published private(set) var conversationContextsByKey: [String: ConversationContext] = [:]
    @Published private(set) var productOutcomeStats: ProductOutcomeStats = .empty
    @Published private(set) var productLoveMetrics: ProductLoveMetrics = ProductLoveMetricStore.load()
    @Published private(set) var briefFetchLimit = 500

    @Published private(set) var handledCardKeys: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "handledCardKeys") ?? []
        return Set(saved)
    }()

    let database: AppDatabase
    let repository: BriefRepository
    let llmClient: LLMClient
    let llmModel: String
    let llmProvider: LLMProvider?
    let isLLMConfigured: Bool
    let basePrompt: String
    var adapters: [String: any MessengerAdapter] = [:]
    var onOpenSettings: (() -> Void)?
    /// Triggers the full poll → summarize cycle (wired by AppDelegate).
    /// Used by the brief header's Refresh button.
    var onRequestRefresh: (() -> Void)?
    /// Wipes demo data and relaunches the setup wizard (wired by AppDelegate).
    var onExitDemo: (() -> Void)?
    /// Fires whenever `briefs` is reloaded. Used by AppDelegate to keep the menu bar
    /// unread badge in sync after the user opens a brief (which flips it to "open").
    var onBriefsChanged: (() -> Void)?
    /// Runs one agent planning cycle now (wired by AppDelegate to AgentEngine.trigger).
    /// Used by the command bar's "catch me up" / "draft all waiting" commands.
    var onTriggerAgentCycle: (() async -> Void)?

    /// Shared contact directory — one instance app-wide. Lazily built so callers can
    /// always read it via @EnvironmentObject from the chat window or invoke `refresh()`
    /// from the Settings panel. Backing adapters are accessed through the AppState ref,
    /// so the directory always sees the current adapter list.
    lazy var contactDirectory: ContactDirectory = {
        ContactDirectory(
            adapters: { [weak self] in
                guard let self else { return [] }
                return Array(self.adapters.values)
            },
            repository: repository
        )
    }()

    init(database: AppDatabase,
         llmClient: LLMClient,
         llmModel: String,
         llmProvider: LLMProvider? = nil,
         isLLMConfigured: Bool = true,
         basePrompt: String) {
        self.database = database
        self.repository = BriefRepository(database: database)
        self.llmClient = llmClient
        self.llmModel = llmModel
        self.llmProvider = llmProvider
        self.isLLMConfigured = isLLMConfigured
        self.basePrompt = basePrompt
        self.productLoveMetrics = ProductLoveMetricStore.markActiveToday()
    }

    var briefGroups: [BriefListGroup] {
        BriefListGrouper.group(briefs)
    }

    var selectedBrief: Brief? {
        guard let id = selectedBriefID else { return nil }
        return briefs.first { $0.id == id }
    }

    var unreadCount: Int {
        briefs.filter { $0.briefStatus == .ready }.count
    }

    var lastCheckedDate: Date? {
        serviceHealthMap.values.compactMap(\.lastCheck).max()
    }

    var hasServiceError: Bool {
        serviceHealthMap.values.contains { $0.status == "error" }
    }

    func updateServiceHealth(_ health: [String: AdapterHealthResult.Status]) {
        serviceHealth = health
    }

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
                let healthMap = (try? settingsRepo.loadAllServiceHealth()) ?? [:]
                let heldBack = settingsRepo.loadFirewallHeldBack()
                await MainActor.run {
                    self.briefs = fetched
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

    // MARK: - P2 Scoped delegation (gated auto-send)

    /// Seconds a delegated auto-send stays armed before firing — the Undo window.
    static let autoSendUndoWindow: TimeInterval = AgentAction.delegatedUndoWindow

    /// Cancellable per-action timers for scheduled sends. The timer IS the undo
    /// window: cancelling the task before it fires aborts the send. Keyed by action id.
    private var armedTimers: [Int64: Task<Void, Never>] = [:]

    /// Number of currently armed scheduled sends — surfaced in the menu bar.
    @Published var armedAutoSendCount: Int = 0

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
    private func reconcileScheduledActions() -> Bool {
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

    /// Lazily-created calendar writer. EventKit access is requested on first approve.
    private lazy var calendarActor = CalendarActor()

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

    /// Test hook: when set, bypasses real EventKit and forces the access result
    /// so calendar-approve tests are deterministic regardless of the host's grant state.
    var calendarAccessOverrideForTesting: Bool?

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
    private func markCardHandledForConversation(service: String, conversationId: String) {
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

    func refreshTasks() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let fetched = (try? self.repository.fetchPendingTasks()) ?? []
            await MainActor.run { self.tasks = fetched }
        }
    }

    func completeTask(_ taskID: Int64) {
        do {
            try repository.completeTask(id: taskID)
            refreshTasks()
            showReceipt("Task completed.", actionTitle: "Undo") { [weak self] in
                guard let self else { return }
                do {
                    try self.repository.reopenTask(id: taskID)
                    self.refreshTasks()
                    self.productLoveMetrics = ProductLoveMetricStore.recordUndo()
                } catch {
                    self.lastError = self.friendly(error)
                }
            }
        } catch {
            lastError = friendly(error)
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
              let json = BriefJSON.decodeLenient(from: brief.openingSummary) else { return }
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
                guard let json = BriefJSON.decodeLenient(from: brief.openingSummary)
                else { return false }
                return json.cards.contains { card in
                    card.priority == "high" &&
                    !isCardHandled(briefID: brief.id ?? -1, cardID: card.id)
                }
            }
        nowNeedsAttention = todayHighUnhandled
    }

    func fetchNeedsReplyCards() -> [(card: BriefCardRecord, briefCreatedAt: Date)] {
        (try? repository.fetchRecentHighPriorityCards(limit: 30)) ?? []
    }

    func makeChatViewModel() -> ChatViewModel {
        ChatViewModel(appState: self)
    }

    func makeSettingsRepository() -> SettingsRepository {
        SettingsRepository(database: database)
    }

    func startDemoMode() {
        do {
            try DemoSeeder.seed(into: database)
            productLoveMetrics = ProductLoveMetricStore.recordDemoStart()
            let task = refreshBriefs()
            Task { @MainActor in
                await task.value
                selectedBriefID = try? repository.latestBriefID()
                showReceipt("Sample command center opened. This is synthetic demo data.")
            }
        } catch {
            lastError = friendly(error)
        }
    }

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

    // MARK: - Error mapping

    /// Maps raw Swift/URLSession/Ollama errors to user-friendly one-liners.
    /// Call this instead of bare `error.localizedDescription` at user-visible boundaries.
    func friendly(_ error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("401") || raw.contains("unauthorized") || raw.contains("forbidden") || raw.contains("api key") {
            return "API key invalid or expired — check your AI settings."
        }
        if raw.contains("429") || raw.contains("rate limit") || raw.contains("too many") {
            return "Too many requests — try again in a moment."
        }
        if raw.contains("timeout") || raw.contains("timed out") {
            return "Request timed out — check your connection."
        }
        if raw.contains("connection refused") || raw.contains("ollama") || raw.contains("localhost") || raw.contains("127.0.0.1") {
            return "Couldn't reach Ollama — make sure it's running."
        }
        if raw.contains("network") || raw.contains("offline") || raw.contains("internet") || raw.contains("host") {
            return "Network error — check your connection."
        }
        return error.localizedDescription
    }
}
