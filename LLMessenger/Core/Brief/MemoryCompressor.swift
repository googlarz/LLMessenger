// LLMessenger/Core/Brief/MemoryCompressor.swift
import Foundation

struct MemoryCompressor {
    let client: LLMClient
    let model: String
    let basePrompt: String

    func compress(briefID: Int64, repository: BriefRepository) async throws {
        guard let brief = try repository.fetchBrief(id: briefID),
              brief.episodicSummary == nil else {
            return
        }

        let messages = try repository.fetchMessages(forBriefID: briefID)
        guard !messages.isEmpty else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, d MMM HH:mm"

        let byConversation = Dictionary(grouping: messages, by: { $0.conversationId })
        let blocks = byConversation.keys.sorted().map { convId -> String in
            let convMsgs = byConversation[convId]!.sorted { $0.timestamp < $1.timestamp }
            let lines = convMsgs.map { "[\(dateFormatter.string(from: $0.timestamp))] \($0.sender): \($0.text)" }
            return "=== \(convId) ===\n" + lines.joined(separator: "\n")
        }
        let threadText = blocks.joined(separator: "\n\n")

        let systemPrompt = PromptBuilder.build(
            mode: .compressor,
            basePrompt: basePrompt,
            services: [],
            episodicSummaries: [],
            now: Date()
        )

        let llmMessages: [LLMMessage] = [
            LLMMessage(role: .system, content: systemPrompt),
            LLMMessage(role: .user,   content: threadText)
        ]

        let response = try await client.complete(
            model: model, messages: llmMessages, maxTokens: 350
        )

        var updated = brief
        updated.episodicSummary = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        try repository.update(brief: updated)
    }
}
