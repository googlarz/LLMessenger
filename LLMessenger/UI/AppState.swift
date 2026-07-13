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
    /// Live adapter status, pushed by AppDelegate on every poll event. Source of
    /// truth for all status reads. `serviceHealthMap` (DB rows, loaded in
    /// refreshBriefs) is kept only for `lastCheck` timestamps.
    @Published var serviceHealth: [String: AdapterHealthResult.Status] = [:]
    @Published var serviceHealthMap: [String: ServiceHealth] = [:]
    @Published var nextPollDate: Date?
    @Published var lastError: String?
    @Published var userReceipt: UserReceipt?
    @Published var briefGenerationState: BriefGenerationState = .cached
    @Published var briefPipelineHealth: BriefPipelineHealth = .healthy
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

    // Stored state for the P2 delegation section (AppState+Delegation.swift) —
    // extensions cannot hold stored properties, so it lives here.
    /// Cancellable per-action timers for scheduled sends. The timer IS the undo
    /// window: cancelling the task before it fires aborts the send. Keyed by action id.
    var armedTimers: [Int64: Task<Void, Never>] = [:]
    /// Number of currently armed scheduled sends — surfaced in the menu bar.
    @Published var armedAutoSendCount: Int = 0
    /// Lazily-created calendar writer. EventKit access is requested on first approve.
    lazy var calendarActor = CalendarActor()
    /// Test hook: when set, bypasses real EventKit and forces the access result
    /// so calendar-approve tests are deterministic regardless of the host's grant state.
    var calendarAccessOverrideForTesting: Bool?

    @Published var contextSuggestions: [ContextSuggestion] = []
    let contextSuggestionEngine = RuleSuggestionEngine()
    // The five vars below were `private(set)` before AppState was split into
    // extension files; setters are internal only so those extensions can write.
    // Views must treat them as read-only — mutate via the AppState+*.swift funcs.
    @Published var conversationContextsByKey: [String: ConversationContext] = [:]
    @Published var productOutcomeStats: ProductOutcomeStats = .empty
    @Published var productLoveMetrics: ProductLoveMetrics = ProductLoveMetricStore.load()
    @Published var briefFetchLimit = 500

    @Published var handledCardKeys: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "handledCardKeys") ?? []
        return Set(saved)
    }()

    let database: AppDatabase
    let repository: BriefRepository
    let llmClient: LLMClient
    @Published var llmModel: String
    @Published var llmProvider: LLMProvider?
    @Published var isLLMConfigured: Bool
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

    func updateLLMConfiguration(
        model: String,
        provider: LLMProvider?,
        isConfigured: Bool
    ) {
        llmModel = model
        llmProvider = provider
        self.isLLMConfigured = isConfigured
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
        serviceHealth.values.contains(.error)
    }

    func updateServiceHealth(_ health: [String: AdapterHealthResult.Status]) {
        serviceHealth = health
    }

}
