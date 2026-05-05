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

        let threadText = messages
            .map { "\($0.sender): \($0.text)" }
            .joined(separator: "\n")

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
            model: model, messages: llmMessages, maxTokens: 200
        )

        var updated = brief
        updated.episodicSummary = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        try repository.update(brief: updated)
    }
}
