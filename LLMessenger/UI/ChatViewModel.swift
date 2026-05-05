// LLMessenger/UI/ChatViewModel.swift
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var threadItems: [ThreadItem] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false

    private let appState: AppState
    private var currentBrief: Brief?

    init(appState: AppState) {
        self.appState = appState
    }

    func loadBrief(_ brief: Brief) async throws {
        currentBrief = brief
        let messages = try appState.repository.fetchMessages(forBriefID: brief.id!)
        threadItems = messages.map { .message($0) }
    }

    func send() async {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let brief = currentBrief else { return }

        let userText = inputText
        inputText = ""
        isLoading = true
        defer { isLoading = false }

        let mode: LLMMode = userText.lowercased().hasPrefix("reply to") ||
                             userText.lowercased().hasPrefix("draft reply")
            ? .replyDrafter
            : .conversationalist

        do {
            let recent = (try? appState.repository.recentEpisodicSummaries(limit: 3)) ?? []
            let services: [String]
            if let data = brief.services.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                services = arr
            } else {
                services = []
            }
            let systemPrompt = PromptBuilder.build(
                mode: mode,
                basePrompt: appState.basePrompt,
                services: services,
                episodicSummaries: recent,
                now: Date()
            )
            let threadText = threadItems.compactMap { item -> String? in
                if case .message(let m) = item { return "[\(m.service)] \(m.sender): \(m.text)" }
                return nil
            }.joined(separator: "\n")

            let chatMessages: [LLMMessage] = [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user, content: threadText + "\n\nUser: " + userText)
            ]

            let response = try await appState.llmClient.complete(
                model: appState.llmModel,
                messages: chatMessages,
                maxTokens: 600
            )
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if mode == .replyDrafter {
                let draft = ReplyDraft(id: UUID(), text: responseText,
                                      conversationID: "unknown",
                                      senderName: "")
                threadItems.append(.replyDraft(id: draft.id, draft: draft))
            } else {
                threadItems.append(.assistantResponse(id: UUID(), text: responseText))
            }
        } catch {
            threadItems.append(.assistantResponse(id: UUID(),
                                                   text: "Error: \(error.localizedDescription)"))
        }
    }

    func discardDraft(id: UUID) {
        threadItems.removeAll {
            if case .replyDraft(let i, _) = $0 { return i == id }
            return false
        }
    }

    func sendDraft(_ draft: ReplyDraft) async throws {
        let serviceKey = draft.conversationID.components(separatedBy: ":").first ?? ""
        guard let adapter = appState.adapters[serviceKey] ?? appState.adapters.values.first
        else { return }
        try await adapter.send(conversationID: draft.conversationID, text: draft.text)
        discardDraft(id: draft.id)
    }
}
