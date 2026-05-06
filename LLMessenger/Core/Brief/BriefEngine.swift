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
    private var briefingInFlight = false

    init(database: AppDatabase, client: LLMClient, model: String, basePrompt: String) {
        self.database = database
        self.client = client
        self.model = model
        self.basePrompt = basePrompt
        self.repository = BriefRepository(database: database)
    }

    @discardableResult
    func processNewMessages() async throws -> Int64? {
        guard !briefingInFlight else { return nil }
        briefingInFlight = true
        defer { briefingInFlight = false }

        let messages = try repository.fetchUnattachedMessages()
        guard !messages.isEmpty else { return nil }

        // Step 1: Compress oldest uncompressed Brief (non-fatal; oldest-first avoids starvation)
        if let prev = try repository.fetchOldestUncompressedBrief(), let prevID = prev.id {
            let compressor = MemoryCompressor(client: client, model: model, basePrompt: basePrompt)
            try? await compressor.compress(briefID: prevID, repository: repository)
        }

        // Step 2: Group messages by service
        let messagesByService = Dictionary(grouping: messages, by: { $0.service })
        let services = Array(messagesByService.keys).sorted()

        // Step 3: Per-service LLM call with its own episodic context
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, d MMM HH:mm"

        var allCards: [[String: Any]] = []
        var totalMessages = 0
        var totalThreads = 0
        var totalPeople = 0
        var parsedServices: Set<String> = []

        for service in services {
            let serviceMessages = messagesByService[service] ?? []

            let recent = try repository.recentEpisodicSummaries(service: service, limit: 3)
            let systemPrompt = PromptBuilder.build(
                mode: .summarizer,
                basePrompt: basePrompt,
                services: [service],
                episodicSummaries: recent,
                now: Date()
            )
            let byConversation: [String: [Message]] = Dictionary(grouping: serviceMessages, by: { $0.conversationId })
            var conversationBlocks: [String] = []
            for convId in byConversation.keys.sorted() {
                let convMessages = byConversation[convId]!.sorted { $0.timestamp < $1.timestamp }
                // Cap at 100 most-recent messages per conversation to keep prompts manageable.
                let capped = convMessages.count > 100 ? Array(convMessages.suffix(100)) : convMessages
                let lines = capped.map { "[\(dateFormatter.string(from: $0.timestamp))] \($0.sender): \($0.text)" }
                let omitted = convMessages.count - capped.count
                var block = "=== \(convId) ===\n"
                if omitted > 0 { block += "[\(omitted) earlier messages omitted]\n" }
                block += lines.joined(separator: "\n")
                conversationBlocks.append(block)
            }
            let threadText = conversationBlocks.joined(separator: "\n\n")

            let response = try await client.complete(
                model: model,
                messages: [
                    LLMMessage(role: .system, content: systemPrompt),
                    LLMMessage(role: .user,   content: threadText)
                ],
                maxTokens: 4000
            )

            var text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("```") {
                text = text
                    .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
            }

            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parsedServices.insert(service)
                totalMessages += json["total_messages"] as? Int ?? serviceMessages.count
                totalThreads  += json["total_threads"]  as? Int ?? 0
                totalPeople   += json["total_people"]   as? Int ?? 0
                if let cards = json["cards"] as? [[String: Any]] {
                    allCards.append(contentsOf: cards)
                }
            }
        }

        // Step 4: Guard against blank briefs — messages stay unattached if LLM returned nothing.
        guard !allCards.isEmpty else { return nil }

        let merged: [String: Any] = [
            "total_messages": totalMessages,
            "total_threads":  totalThreads,
            "total_people":   totalPeople,
            "cards":          allCards
        ]
        let openingSummary = (try? JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted))
            .flatMap { String(data: $0, encoding: .utf8) }

        // Step 5: Create the Brief and attach messages
        let notificationText = "\(messages.count) new messages · \(services.joined(separator: ", "))"
        let servicesJSON = (try? String(data: JSONSerialization.data(withJSONObject: services), encoding: .utf8)) ?? "[]"
        let brief = Brief(
            id: nil,
            createdAt: Date(),
            status: BriefStatus.ready.rawValue,
            services: servicesJSON,
            openingSummary: openingSummary,
            notificationText: notificationText,
            episodicSummary: nil
        )
        let briefID = try repository.insertBrief(brief)
        // Only attach messages from services whose LLM response parsed successfully.
        // Messages from failed services stay unattached for the next poll cycle.
        let messagesToAttach = messages.filter { parsedServices.contains($0.service) }
        try repository.attach(messages: messagesToAttach, toBriefID: briefID)

        return briefID
    }

    // Fetch from adapters for the last N hours, store any new messages, and create a brief.
    @discardableResult
    func summarizeLast(hours: Int, adapters: [String: any MessengerAdapter]) async throws -> Int64? {
        guard !briefingInFlight else { return nil }
        briefingInFlight = true
        defer { briefingInFlight = false }

        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        let fetchConfig = FetchConfig(mode: .byTime(since: since))
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, d MMM HH:mm"

        var allCards: [[String: Any]] = []
        var totalMessages = 0
        var totalThreads = 0
        var totalPeople = 0
        var activeServices: [String] = []
        var messagesToAttach: [Message] = []

        for (serviceID, adapter) in adapters.sorted(by: { $0.key < $1.key }) {
            do {
                let result = try await adapter.fetch(config: fetchConfig)
                guard !result.conversations.isEmpty else { continue }

                // Persist rows so the chat panel can display them regardless of LLM outcome.
                let newlyStored = try repository.storeMessages(from: result, service: serviceID)

                let recent = try repository.recentEpisodicSummaries(service: serviceID, limit: 3)
                let systemPrompt = PromptBuilder.build(
                    mode: .summarizer,
                    basePrompt: basePrompt,
                    services: [serviceID],
                    episodicSummaries: recent,
                    now: Date()
                )

                var conversationBlocks: [String] = []
                var msgCount = 0
                for conv in result.conversations {
                    let sorted = conv.messages.sorted { $0.timestamp < $1.timestamp }
                    // Cap at 100 most-recent messages per conversation to keep prompts manageable.
                    let capped = sorted.count > 100 ? Array(sorted.suffix(100)) : sorted
                    let omitted = sorted.count - capped.count
                    let lines = capped.map { "[\(dateFormatter.string(from: $0.timestamp))] \($0.sender): \($0.text)" }
                    var block = "=== \(conv.id) ===\n"
                    if omitted > 0 { block += "[\(omitted) earlier messages omitted]\n" }
                    block += lines.joined(separator: "\n")
                    conversationBlocks.append(block)
                    msgCount += sorted.count
                }
                let threadText = conversationBlocks.joined(separator: "\n\n")
                guard !threadText.isEmpty else { continue }

                let response = try await client.complete(
                    model: model,
                    messages: [
                        LLMMessage(role: .system, content: systemPrompt),
                        LLMMessage(role: .user,   content: threadText)
                    ],
                    maxTokens: 4000
                )

                var text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("```") {
                    text = text
                        .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
                }

                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Only mark this service as successfully summarized when JSON parsed.
                    activeServices.append(serviceID)
                    messagesToAttach.append(contentsOf: newlyStored)
                    totalMessages += json["total_messages"] as? Int ?? msgCount
                    totalThreads  += json["total_threads"]  as? Int ?? 0
                    totalPeople   += json["total_people"]   as? Int ?? 0
                    if let cards = json["cards"] as? [[String: Any]] {
                        allCards.append(contentsOf: cards)
                    }
                }
            } catch {
                // Skip failed adapter; its stored messages stay unattached for the next cycle.
                continue
            }
        }

        guard !allCards.isEmpty else { return nil }

        let merged: [String: Any] = [
            "total_messages": totalMessages,
            "total_threads":  totalThreads,
            "total_people":   totalPeople,
            "cards":          allCards
        ]
        let openingSummary = (try? JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted))
            .flatMap { String(data: $0, encoding: .utf8) }

        let servicesJSON = (try? String(data: JSONSerialization.data(withJSONObject: activeServices), encoding: .utf8)) ?? "[]"
        let brief = Brief(
            id: nil,
            createdAt: Date(),
            status: BriefStatus.ready.rawValue,
            services: servicesJSON,
            openingSummary: openingSummary,
            notificationText: "\(totalMessages) messages (last \(hours)h) · \(activeServices.joined(separator: ", "))",
            episodicSummary: nil
        )
        let briefID = try repository.insertBrief(brief)
        if !messagesToAttach.isEmpty {
            try repository.attach(messages: messagesToAttach, toBriefID: briefID)
        }
        return briefID
    }
}
