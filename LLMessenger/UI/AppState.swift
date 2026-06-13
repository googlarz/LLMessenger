// LLMessenger/UI/AppState.swift
import Foundation
import AppKit

// MARK: - Shared Value Types

struct ReplyDraft: Identifiable, Equatable {
    let id: UUID
    var text: String
    let serviceID: String
    let conversationID: String
    let senderName: String
}

struct ConversationOption: Identifiable, Equatable {
    let id = UUID()
    let number: Int
    let service: String       // "signal", "telegram", etc.
    let convId: String        // raw conversation ID
    let displayName: String   // "Alice Müller", "Work group"
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
    @Published var briefs: [Brief] = []
    @Published var tasks: [BriefTask] = []
    @Published var selectedBriefID: Int64?
    @Published var serviceHealth: [String: AdapterHealthResult.Status] = [:]
    @Published var serviceHealthMap: [String: ServiceHealth] = [:]
    @Published var nextPollDate: Date?
    @Published var lastError: String?
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
            return refreshBriefs()
        } catch {
            lastError = error.localizedDescription
            return Task {}
        }
    }

    @discardableResult
    func refreshBriefs() -> Task<Void, Never> {
        let settingsRepo = makeSettingsRepository()
        return Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let fetched = try self.repository.fetchAllBriefs()
                let healthMap = (try? settingsRepo.loadAllServiceHealth()) ?? [:]
                await MainActor.run {
                    self.briefs = fetched
                    self.serviceHealthMap = healthMap
                    self.recomputeNowState()
                    self.onBriefsChanged?()
                    self.reloadOwedReplies()
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    func reloadOwedReplies() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let contexts = try self.repository.fetchAllConversationContexts()
                let owed = try OwedReplyDeriver().derive(db: self.database, contexts: contexts)
                await MainActor.run {
                    self.owedReplies = owed
                    self.owedCount = owed.count
                    self.onBriefsChanged?()
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    func markCardHandled(briefID: Int64, cardID: String) {
        handledCardKeys.insert("\(briefID):\(cardID)")
        UserDefaults.standard.set(Array(handledCardKeys), forKey: "handledCardKeys")
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
              let summary = brief.openingSummary,
              let data = summary.data(using: .utf8),
              let json = try? JSONDecoder().decode(BriefJSON.self, from: data) else { return }
        for card in json.cards {
            markCardHandled(briefID: briefID, cardID: card.id)
        }
    }

    func setPinnedBrief(briefID: Int64, pinned: Bool) {
        do {
            try repository.setPinned(briefID: briefID, pinned: pinned)
            refreshBriefs()
        } catch {
            lastError = error.localizedDescription
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unarchiveBrief(_ briefID: Int64) {
        do {
            try repository.setArchived(briefID: briefID, archivedAt: nil)
            refreshBriefs()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func snoozeBrief(id briefID: Int64, until date: Date) {
        do {
            try repository.setSnoozed(briefID: briefID, snoozedUntil: date)
            refreshBriefs()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func recomputeNowState() {
        let cal = Calendar.current
        let todayHighUnhandled = briefs
            .filter { cal.isDateInToday($0.createdAt) && $0.archivedAt == nil }
            .contains { brief in
                guard let summary = brief.openingSummary,
                      let data = summary.data(using: .utf8),
                      let json = try? JSONDecoder().decode(BriefJSON.self, from: data)
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

    // MARK: - Conversation Context

    func saveConversationContext(service: String, conversationId: String, label: String, priorityHint: String) {
        let ctx = ConversationContext(
            service: service,
            conversationId: conversationId,
            label: label,
            priorityHint: priorityHint,
            updatedAt: Date()
        )
        do {
            try repository.upsertConversationContext(ctx)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func fetchConversationContext(service: String, conversationId: String) -> ConversationContext? {
        try? repository.fetchConversationContext(service: service, conversationId: conversationId)
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
        } catch {
            lastError = error.localizedDescription
        }
    }
}
