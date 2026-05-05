// LLMessenger/Core/Brief/BriefEngine.swift
import Foundation
import GRDB

@MainActor
final class BriefEngine {
    private let database: AppDatabase
    private let client: LLMClient
    private let model: String
    private let basePrompt: String
    private let repository: BriefRepository

    init(database: AppDatabase, client: LLMClient, model: String, basePrompt: String) {
        self.database = database
        self.client = client
        self.model = model
        self.basePrompt = basePrompt
        self.repository = BriefRepository(database: database)
    }

    @discardableResult
    func processNewMessages() async throws -> Int64? {
        let messages = try repository.fetchUnattachedMessages()
        guard !messages.isEmpty else { return nil }

        // Step 1: Compress previous uncompressed Brief if any
        if let prev = try repository.fetchLatestUncompressedBrief() {
            let compressor = MemoryCompressor(client: client, model: model, basePrompt: basePrompt)
            try await compressor.compress(briefID: prev.id!, repository: repository)
        }

        // Step 2: Determine services + privacy mode
        let services = Array(Set(messages.map { $0.service })).sorted()
        let serviceConfigs = try await database.dbQueue.read { db in
            try ServiceConfig.fetchAll(db).filter { services.contains($0.service) }
        }
        let allEager = !serviceConfigs.isEmpty && serviceConfigs.allSatisfy { $0.privacyMode == "eager" }

        // Step 3: Build notification + optional LLM summary
        let notificationText = "\(messages.count) new messages · \(services.joined(separator: ", "))"
        var openingSummary: String? = nil

        if allEager {
            let recent = try repository.recentEpisodicSummaries(limit: 3)
            let systemPrompt = PromptBuilder.build(
                mode: .summarizer,
                basePrompt: basePrompt,
                services: services,
                episodicSummaries: recent,
                now: Date()
            )
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEE, d MMM HH:mm"
            let threadText = messages
                .sorted { $0.timestamp < $1.timestamp }
                .map { "[\(dateFormatter.string(from: $0.timestamp))] [\($0.service)] \($0.sender): \($0.text)" }
                .joined(separator: "\n")
            let response = try await client.complete(
                model: model,
                messages: [
                    LLMMessage(role: .system, content: systemPrompt),
                    LLMMessage(role: .user,   content: threadText)
                ],
                maxTokens: 2000
            )
            openingSummary = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Step 4: Create the Brief
        let servicesJSON = (try? String(data: JSONSerialization.data(withJSONObject: services), encoding: .utf8)) ?? "[]"
        let brief = Brief(
            id: nil,
            createdAt: Date(),
            status: "ready",
            services: servicesJSON,
            openingSummary: openingSummary,
            notificationText: notificationText,
            episodicSummary: nil
        )
        let briefID = try repository.insertBrief(brief)

        // Step 5: Attach messages
        try repository.attach(messages: messages, toBriefID: briefID)

        return briefID
    }
}
