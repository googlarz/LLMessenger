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

enum ThreadItem: Identifiable {
    case message(Message)
    case userMessage(id: UUID, text: String)
    case assistantResponse(id: UUID, text: String)
    case replyDraft(id: UUID, draft: ReplyDraft)
    /// Shown when a reply intent targets multiple conversations — user picks one by number.
    case conversationPicker(id: UUID, originalRequest: String, options: [ConversationOption])

    var id: String {
        switch self {
        case .message(let m):                return "msg-\(m.id ?? 0)"
        case .userMessage(let i, _):         return "user-\(i)"
        case .assistantResponse(let i, _):   return "asst-\(i)"
        case .replyDraft(let i, _):          return "draft-\(i)"
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
    @Published var selectedBriefID: Int64?
    @Published var serviceHealth: [String: AdapterHealthResult.Status] = [:]
    @Published var nextPollDate: Date?
    @Published var lastError: String?
    @Published var briefGenerationState: BriefGenerationState = .cached

    let database: AppDatabase
    let repository: BriefRepository
    let llmClient: LLMClient
    let llmModel: String
    let llmProvider: LLMProvider?
    let isLLMConfigured: Bool
    let basePrompt: String
    var adapters: [String: any MessengerAdapter] = [:]
    var onOpenSettings: (() -> Void)?

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

    func updateServiceHealth(_ health: [String: AdapterHealthResult.Status]) {
        serviceHealth = health
    }

    func markAsOpen(briefID: Int64) {
        do {
            try repository.markAsOpen(briefID: briefID)
            InstrumentationManager.shared.track(event: .briefOpened, metadata: ["briefID": briefID])
            refreshBriefs()
        } catch {
            // silently ignore — UI state will be stale at worst
        }
    }

    func refreshBriefs() {
        do {
            briefs = try repository.fetchAllBriefs()
        } catch {
            // Silently ignore — UI shows empty state
        }
    }

    func makeChatViewModel() -> ChatViewModel {
        ChatViewModel(appState: self)
    }

    func makeSettingsRepository() -> SettingsRepository {
        SettingsRepository(database: database)
    }
}
