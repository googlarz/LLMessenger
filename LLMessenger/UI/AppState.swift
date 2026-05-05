// LLMessenger/UI/AppState.swift
import Foundation
import AppKit

// MARK: - Shared Value Types

struct ReplyDraft: Identifiable, Equatable {
    let id: UUID
    var text: String
    let conversationID: String
    let senderName: String
}

enum ThreadItem: Identifiable {
    case message(Message)
    case assistantResponse(id: UUID, text: String)
    case replyDraft(id: UUID, draft: ReplyDraft)

    var id: String {
        switch self {
        case .message(let m):              return "msg-\(m.id ?? 0)"
        case .assistantResponse(let i, _): return "asst-\(i)"
        case .replyDraft(let i, _):        return "draft-\(i)"
        }
    }
}

struct BriefListGroup: Identifiable {
    let id: String
    let label: String
    let briefs: [Brief]
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

    private static func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    @Published var briefs: [Brief] = []
    @Published var selectedBriefID: Int64?
    @Published var serviceHealth: [String: AdapterHealthResult.Status] = [:]

    let database: AppDatabase
    let repository: BriefRepository
    let llmClient: LLMClient
    let llmModel: String
    let basePrompt: String
    var adapters: [String: any MessengerAdapter] = [:]

    init(database: AppDatabase,
         llmClient: LLMClient,
         llmModel: String,
         basePrompt: String) {
        self.database = database
        self.repository = BriefRepository(database: database)
        self.llmClient = llmClient
        self.llmModel = llmModel
        self.basePrompt = basePrompt
    }

    var briefGroups: [BriefListGroup] {
        BriefListGrouper.group(briefs)
    }

    var selectedBrief: Brief? {
        guard let id = selectedBriefID else { return nil }
        return briefs.first { $0.id == id }
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

    func reloadConfig() {
        refreshBriefs()
    }
}
