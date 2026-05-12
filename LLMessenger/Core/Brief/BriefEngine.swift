// LLMessenger/Core/Brief/BriefEngine.swift
import Foundation
import GRDB

enum BriefEngineValidationError: Error {
    case emptyCards
    case wrongService(cardId: String, service: String)
    case missingSourceMessageIds(cardId: String)
    case unknownSourceMessageId(cardId: String, messageId: String)
    case unknownQuoteMessageId(cardId: String, messageId: String)
}

@MainActor
final class BriefEngine {
    private let maxRecentContextMessages = 20
    private let recentContextWindow: TimeInterval = 24 * 3600
    private let database: AppDatabase
    var client: LLMClient
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
    func processNewMessages(adapters: [String: any MessengerAdapter] = [:]) async throws -> Int64? {
        guard !briefingInFlight else { return nil }
        briefingInFlight = true
        defer { briefingInFlight = false }

        let messages = try repository.fetchUnattachedMessages()
        guard !messages.isEmpty else { return nil }

        // Step 1: Compress oldest uncompressed Brief (non-fatal; oldest-first avoids starvation).
        // On failure, write an empty-string sentinel so the same brief is not retried every cycle.
        if let prev = try repository.fetchOldestUncompressedBrief(), let prevID = prev.id {
            let compressor = MemoryCompressor(client: client, model: model, basePrompt: basePrompt)
            do {
                try await compressor.compress(briefID: prevID, repository: repository)
            } catch {
                try? repository.setEpisodicSummary(briefID: prevID, summary: "")
            }
        }

        // Step 2: Group messages by service
        let messagesByService = Dictionary(grouping: messages, by: { $0.service })
        let services = Array(messagesByService.keys).sorted()

        // Step 3: Per-service LLM call with its own episodic context
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, d MMM HH:mm"

        var allCards: [BriefCard] = []
        var totalMessages = 0
        var totalThreads = 0
        var totalPeople = 0
        var parsedServices: Set<String> = []
        var failedServices: Set<String> = []
        var sourceMessagesByService: [String: [String: Message]] = [:]

        struct ServiceResult {
            let service: String
            let cards: [BriefCard]
            let stats: (messages: Int, threads: Int, people: Int)
            let sourceMessages: [String: Message]
            let success: Bool
        }

        let results = await withTaskGroup(of: ServiceResult?.self) { group in
            for service in services {
                let serviceMessages = messagesByService[service] ?? []
                let recent = (try? repository.recentEpisodicSummaries(service: service, limit: 3)) ?? []
                let signalAdapter = adapters[service] as? SignalCLIAdapter
                
                group.addTask {
                    do {
                        let systemPrompt = PromptBuilder.build(
                            mode: .summarizer,
                            basePrompt: self.basePrompt,
                            services: [service],
                            episodicSummaries: recent,
                            now: Date()
                        )
                        let byConversation: [String: [Message]] = Dictionary(grouping: serviceMessages, by: { $0.conversationId })
                        let maxConversations = 30
                        let rankedConvIds = byConversation.keys
                            .sorted { (byConversation[$0]?.count ?? 0) > (byConversation[$1]?.count ?? 0) }
                            .prefix(maxConversations)
                        
                        var conversationBlocks: [String] = []
                        for convId in rankedConvIds {
                            let convMessages = byConversation[convId]!.sorted { $0.timestamp < $1.timestamp }
                            let capped = convMessages.count > 100 ? Array(convMessages.suffix(100)) : convMessages
                            let convHeader = convMessages.first?.conversationName
                                ?? signalAdapter?.groupName(for: convId)
                                ?? signalAdapter?.contactName(for: convId)
                                ?? convId
                            let omitted = convMessages.count - capped.count
                            // SECURITY: message.text is inserted into the LLM user content without escaping.
                            // A malicious sender whose text contains "=== [service] id | Title ===" could
                            // inject a fake conversation header. Mitigation: strip or escape "===" from
                            // user-supplied text before building conversation blocks. Tracked as a known gap.
                            let block = try self.buildConversationBlock(
                                service: service,
                                conversationID: convId,
                                conversationTitle: convHeader,
                                newMessages: capped,
                                omittedNewMessageCount: omitted,
                                dateFormatter: dateFormatter,
                                senderNameResolver: { sender in
                                    let resolved = signalAdapter?.contactName(for: sender)
                                    return resolved ?? (sender.count > 20 ? "Unknown" : sender)
                                }
                            )
                            conversationBlocks.append(block)
                        }
                        let threadText = conversationBlocks.joined(separator: "\n\n")

                        let response = try await self.client.complete(
                            model: self.model,
                            messages: [
                                LLMMessage(role: .system, content: systemPrompt),
                                LLMMessage(role: .user,   content: threadText)
                            ],
                            maxTokens: 4000
                        )

                        if let parsed = try? self.decodeAndValidateBrief(response.text, service: service, sourceMessages: serviceMessages) {
                            return ServiceResult(
                                service: service,
                                cards: parsed.cards,
                                stats: (parsed.totalMessages ?? serviceMessages.count, parsed.totalThreads ?? 0, parsed.totalPeople ?? 0),
                                // uniquingKeysWith: keeps the first occurrence when Signal produces
                                // duplicate messageIds (same sender+timestamp), preventing a crash.
                                sourceMessages: Dictionary(serviceMessages.map { ($0.messageId, $0) }, uniquingKeysWith: { a, _ in a }),
                                success: true
                            )
                        } else {
                            return ServiceResult(service: service, cards: [], stats: (0, 0, 0), sourceMessages: [:], success: false)
                        }
                    } catch {
                        return ServiceResult(service: service, cards: [], stats: (0, 0, 0), sourceMessages: [:], success: false)
                    }
                }
            }
            
            var collected: [ServiceResult] = []
            for await res in group {
                if let r = res { collected.append(r) }
            }
            return collected
        }

        for res in results {
            if res.success {
                parsedServices.insert(res.service)
                sourceMessagesByService[res.service] = res.sourceMessages
                totalMessages += res.stats.messages
                totalThreads += res.stats.threads
                totalPeople += res.stats.people
                allCards.append(contentsOf: res.cards)
            } else {
                failedServices.insert(res.service)
            }
        }

        // Step 4: Guard against blank briefs — messages stay unattached if LLM returned nothing.
        guard !allCards.isEmpty else { return nil }

        let merged = BriefJSON(
            totalMessages: totalMessages,
            totalThreads: totalThreads,
            totalPeople: totalPeople,
            cards: allCards
        )
        let openingSummary = try encodeBriefJSON(merged)

        // Step 5: Create the Brief and attach messages
        let notificationText = "\(messages.count) new messages · \(services.joined(separator: ", "))"
        let servicesJSON = (try? String(data: JSONSerialization.data(withJSONObject: Array(parsedServices).sorted()), encoding: .utf8)) ?? "[]"
        let failedJSON = failedServices.isEmpty ? nil : (try? String(data: JSONSerialization.data(withJSONObject: Array(failedServices).sorted()), encoding: .utf8))
        let brief = Brief(
            id: nil,
            createdAt: Date(),
            status: BriefStatus.ready.rawValue,
            services: servicesJSON,
            failedServices: failedJSON,
            openingSummary: openingSummary,
            notificationText: notificationText,
            episodicSummary: nil
        )
        let briefID = try repository.insertBrief(brief)
        try persistBriefCards(allCards, briefID: briefID, sourceMessagesByService: sourceMessagesByService)
        try persistConversationStates(allCards, sourceMessagesByService: sourceMessagesByService)
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

        // Compress oldest uncompressed brief before creating a new one (same as processNewMessages).
        if let prev = try repository.fetchOldestUncompressedBrief(), let prevID = prev.id {
            let compressor = MemoryCompressor(client: client, model: model, basePrompt: basePrompt)
            do {
                try await compressor.compress(briefID: prevID, repository: repository)
            } catch {
                try? repository.setEpisodicSummary(briefID: prevID, summary: "")
            }
        }

        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        let fetchConfig = FetchConfig(mode: .byTime(since: since))
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, d MMM HH:mm"

        var allCards: [BriefCard] = []
        var totalMessages = 0
        var totalThreads = 0
        var totalPeople = 0
        var activeServices: [String] = []
        var failedServices: [String] = []
        var messagesToAttach: [Message] = []
        var sourceMessagesByService: [String: [String: Message]] = [:]

        struct ServiceResult {
            let service: String
            let cards: [BriefCard]
            let stats: (messages: Int, threads: Int, people: Int)
            /// All messages in the time window — used for source-ID validation and card attribution.
            /// Includes previously-briefed messages so the LLM can reference any message in the window.
            let sourceMessages: [Message]
            /// Only unattached messages (briefId == nil) — used to set briefId on this new brief.
            let newlyStored: [Message]
            let success: Bool
        }

        let results = await withTaskGroup(of: ServiceResult?.self) { group in
            // Collect service IDs from both live adapters and DB (covers adapters that failed to start).
            var serviceIDs = Set(adapters.keys)
            // Also include any services that have stored messages in the window (e.g. iMessage polled
            // in the background but whose adapter isn't running at brief-generation time).
            if let storedServices = try? await self.database.dbQueue.read({ db in
                try String.fetchAll(db, sql:
                    "SELECT DISTINCT service FROM messages WHERE timestamp > ? AND isSent = 0",
                    arguments: [since])
            }) { storedServices.forEach { serviceIDs.insert($0) } }

            for serviceID in serviceIDs.sorted() {
                group.addTask {
                    do {
                        // 1. Try live adapter fetch. Start the adapter first if it hasn't
                        // been started yet (e.g. iMessage disabled during startup, or FDA
                        // was granted after the app launched).
                        var adapterResult: AdapterFetchResult? = nil
                        if let adapter = adapters[serviceID] {
                            if adapter.healthStatus != .ok {
                                try? await adapter.start()
                            }
                            do {
                                adapterResult = try await adapter.fetch(config: fetchConfig)
                            } catch {
                                print("[BriefEngine] \(serviceID): adapter fetch failed: \(error)")
                            }
                        }

                        // 2. If adapter returned nothing, fall back to stored DB messages.
                        let newlyStored: [Message]
                        let sourceMessages: [Message]
                        let conversations: [AdapterConversation]
                        if let result = adapterResult, !result.conversations.isEmpty {
                            let totalMsgs = result.conversations.reduce(0) { $0 + $1.messages.count }
                            print("[BriefEngine] \(serviceID): adapter returned \(result.conversations.count) conversations, \(totalMsgs) messages")
                            newlyStored = try self.repository.storeMessages(from: result, service: serviceID)
                            conversations = result.conversations
                            // Fetch ALL messages in the window PLUS the 24h context window that
                            // buildConversationBlock prepends before the first new message.
                            // Without this, the LLM can reference context message IDs that are
                            // outside 'since' and decodeAndValidateBrief rejects the whole service.
                            let sourceSince = since.addingTimeInterval(-self.recentContextWindow)
                            sourceMessages = try self.repository.fetchMessages(service: serviceID, since: sourceSince)
                        } else {
                            // Adapter unavailable or empty — use messages already stored by the poll loop.
                            let sourceSince = since.addingTimeInterval(-self.recentContextWindow)
                            let dbMessages = try self.repository.fetchMessages(service: serviceID, since: sourceSince)
                            let dbCount = dbMessages.filter { $0.timestamp > since }.count
                            print("[BriefEngine] \(serviceID): using DB fallback, \(dbCount) messages in window (adapter: \(adapterResult == nil ? "nil" : "empty"))")
                            guard !dbMessages.isEmpty else { return nil }
                            // Only attach unattached messages; already-briefed ones are included
                            // in sourceMessages for validation but must not have their briefId
                            // reassigned to this new brief.
                            newlyStored = dbMessages.filter { $0.timestamp > since && $0.briefId == nil }
                            sourceMessages = dbMessages
                            // Reconstruct AdapterConversation-like grouping from stored messages.
                            var byConv: [String: [Message]] = [:]
                            for m in dbMessages { byConv[m.conversationId, default: []].append(m) }
                            conversations = byConv.map { convId, msgs in
                                // Use stored conversationName if available; fall back to raw ID.
                                let convName = msgs.first?.conversationName ?? convId
                                return AdapterConversation(
                                    id: convId, name: convName, type: .dm,
                                    messages: msgs.map { AdapterMessage(id: $0.messageId, sender: $0.sender,
                                                                        text: $0.text, timestamp: $0.timestamp) }
                                )
                            }
                        }

                        let recent = try self.repository.recentEpisodicSummaries(service: serviceID, limit: 3)
                        let systemPrompt = PromptBuilder.build(
                            mode: .summarizer,
                            basePrompt: self.basePrompt,
                            services: [serviceID],
                            episodicSummaries: recent,
                            now: Date()
                        )

                        var conversationBlocks: [String] = []
                        var msgCount = 0
                        for conv in conversations {
                            let sorted = conv.messages.sorted { $0.timestamp < $1.timestamp }
                            let capped = sorted.count > 100 ? Array(sorted.suffix(100)) : sorted
                            let omitted = sorted.count - capped.count
                            let block = try self.buildConversationBlock(
                                service: serviceID,
                                conversationID: conv.id,
                                conversationTitle: conv.name,
                                newMessages: capped.map {
                                    Message(
                                        id: nil,
                                        briefId: nil,
                                        service: serviceID,
                                        conversationId: conv.id,
                                        conversationName: conv.name,
                                        messageId: $0.id,
                                        sender: $0.sender,
                                        text: $0.text,
                                        timestamp: $0.timestamp,
                                        isSent: $0.isFromMe
                                    )
                                },
                                omittedNewMessageCount: omitted,
                                dateFormatter: dateFormatter,
                                senderNameResolver: { $0 }
                            )
                            conversationBlocks.append(block)
                            msgCount += sorted.count
                        }
                        let threadText = conversationBlocks.joined(separator: "\n\n")
                        guard !threadText.isEmpty else { return nil }

                        let response = try await self.client.complete(
                            model: self.model,
                            messages: [
                                LLMMessage(role: .system, content: systemPrompt),
                                LLMMessage(role: .user,   content: threadText)
                            ],
                            maxTokens: 16000
                        )

                        do {
                            let parsed = try self.decodeAndValidateBrief(response.text, service: serviceID, sourceMessages: sourceMessages)
                            return ServiceResult(
                                service: serviceID,
                                cards: parsed.cards,
                                stats: (parsed.totalMessages ?? msgCount, parsed.totalThreads ?? 0, parsed.totalPeople ?? 0),
                                sourceMessages: sourceMessages,
                                newlyStored: newlyStored,
                                success: true
                            )
                        } catch {
                            print("[BriefEngine] \(serviceID) validation failed: \(error)")
                            return ServiceResult(service: serviceID, cards: [], stats: (0, 0, 0), sourceMessages: [], newlyStored: [], success: false)
                        }
                    } catch {
                        print("[BriefEngine] \(serviceID) brief failed: \(error)")
                        return ServiceResult(service: serviceID, cards: [], stats: (0, 0, 0), sourceMessages: [], newlyStored: [], success: false)
                    }
                }
            }
            
            var collected: [ServiceResult] = []
            for await res in group {
                if let r = res { collected.append(r) }
            }
            return collected
        }

        for res in results {
            if res.success {
                activeServices.append(res.service)
                messagesToAttach.append(contentsOf: res.newlyStored)
                sourceMessagesByService[res.service] = Dictionary(res.sourceMessages.map { ($0.messageId, $0) }, uniquingKeysWith: { a, _ in a })
                totalMessages += res.stats.messages
                totalThreads += res.stats.threads
                totalPeople += res.stats.people
                allCards.append(contentsOf: res.cards)
            } else {
                failedServices.append(res.service)
            }
        }

        guard !allCards.isEmpty else { return nil }

        let merged = BriefJSON(
            totalMessages: totalMessages,
            totalThreads: totalThreads,
            totalPeople: totalPeople,
            cards: allCards
        )
        let openingSummary = try encodeBriefJSON(merged)

        let servicesJSON = (try? String(data: JSONSerialization.data(withJSONObject: activeServices), encoding: .utf8)) ?? "[]"
        let failedJSON = failedServices.isEmpty ? nil : (try? String(data: JSONSerialization.data(withJSONObject: failedServices), encoding: .utf8))
        let brief = Brief(
            id: nil,
            createdAt: Date(),
            status: BriefStatus.ready.rawValue,
            services: servicesJSON,
            failedServices: failedJSON,
            openingSummary: openingSummary,
            notificationText: "\(totalMessages) messages (last \(hours)h) · \(activeServices.joined(separator: ", "))",
            episodicSummary: nil,
            windowStart: since
        )
        let briefID = try repository.insertBrief(brief)
        try persistBriefCards(allCards, briefID: briefID, sourceMessagesByService: sourceMessagesByService)
        try persistConversationStates(allCards, sourceMessagesByService: sourceMessagesByService)
        if !messagesToAttach.isEmpty {
            try repository.attach(messages: messagesToAttach, toBriefID: briefID)
        }
        return briefID
    }

    private nonisolated func decodeAndValidateBrief(_ text: String, service: String, sourceMessages: [Message]) throws -> BriefJSON {
        let cleanText = repairJSON(stripMarkdownFences(text))
        guard let data = cleanText.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8"))
        }
        let parsed = try JSONDecoder().decode(BriefJSON.self, from: data)
        guard !parsed.cards.isEmpty else { throw BriefEngineValidationError.emptyCards }

        let sourceIDs = Set(sourceMessages.map(\.messageId))
        var validCards: [BriefCard] = []
        for card in parsed.cards {
            guard card.service == service else {
                print("[BriefEngine] skipping card \(card.id): wrong service \(card.service)")
                continue
            }

            let validSourceIDs = card.sourceMessageIds.filter { !$0.isEmpty && sourceIDs.contains($0) }
            let droppedCount = card.sourceMessageIds.count - validSourceIDs.count
            if droppedCount > 0 {
                print("[BriefEngine] card \(card.id): dropped \(droppedCount) unknown sourceMessageIds")
            }
            guard !validSourceIDs.isEmpty else {
                print("[BriefEngine] skipping card \(card.id): no valid sourceMessageIds")
                continue
            }

            let validQuotes = card.quotes.filter { q in
                guard let mid = q.messageId else { return false }
                return sourceIDs.contains(mid)
            }
            if validQuotes.count < card.quotes.count {
                print("[BriefEngine] card \(card.id): dropped \(card.quotes.count - validQuotes.count) unknown quotes")
            }

            validCards.append(BriefCard(
                id: card.id,
                service: card.service,
                conversationId: card.conversationId,
                conversationTitle: card.conversationTitle,
                headline: card.headline,
                priority: card.priority,
                counts: card.counts,
                summary: card.summary,
                callback: card.callback,
                actionItems: card.actionItems,
                quotes: validQuotes,
                sourceMessageIds: validSourceIDs
            ))
        }

        guard !validCards.isEmpty else { throw BriefEngineValidationError.emptyCards }

        return BriefJSON(
            totalMessages: parsed.totalMessages,
            totalThreads: parsed.totalThreads,
            totalPeople: parsed.totalPeople,
            cards: validCards
        )
    }

    private func persistBriefCards(
        _ cards: [BriefCard],
        briefID: Int64,
        sourceMessagesByService: [String: [String: Message]]
    ) throws {
        let now = Date()
        for card in cards {
            // Always generate a fresh UUID — the LLM-produced card.id is reused across
            // brief runs for the same conversation, causing UNIQUE constraint failures.
            let cardID = UUID().uuidString
            let record = BriefCardRecord(
                id: cardID,
                briefId: briefID,
                service: card.service,
                conversationId: card.conversationId,
                conversationTitle: card.conversationTitle,
                headline: card.headline,
                priority: card.priority,
                summary: card.summary,
                actionItems: try encodeStringArray(card.actionItems),
                callbackText: card.callback,
                sourceMessageIds: try encodeStringArray(card.sourceMessageIds),
                createdAt: now
            )
            do {
                try repository.insertBriefCard(record)
            } catch {
                print("[BriefEngine] persistBriefCards: failed to insert card \(cardID) (\(card.service)/\(card.conversationId)): \(error)")
                continue
            }

            let quoteMessageIDs = Set(card.quotes.compactMap(\.messageId))
            let sources = card.sourceMessageIds.map { messageID in
                let message = sourceMessagesByService[card.service]?[messageID]
                let quote = card.quotes.first { $0.messageId == messageID }
                return BriefCardSource(
                    id: nil,
                    briefCardId: cardID,
                    messageRowId: message?.id,
                    service: card.service,
                    messageId: messageID,
                    sourceRole: quoteMessageIDs.contains(messageID) ? BriefCardSourceRole.quote.rawValue : BriefCardSourceRole.newMessage.rawValue,
                    quoteText: quote?.text,
                    createdAt: now
                )
            }
            do {
                try repository.insertBriefCardSources(sources)
            } catch {
                print("[BriefEngine] persistBriefCards: failed to insert sources for card \(cardID): \(error)")
            }
        }
    }

    private func persistConversationStates(
        _ cards: [BriefCard],
        sourceMessagesByService: [String: [String: Message]]
    ) throws {
        let now = Date()
        for card in cards {
            let serviceMessages = sourceMessagesByService[card.service].map { Array($0.values) } ?? []
            let conversationMessages = serviceMessages
                .filter { $0.conversationId == card.conversationId }
                .sorted(by: messageSortAscending)
            let latestMessageID = conversationMessages.last?.messageId
            let participants = Array(Set(conversationMessages.map { $0.sender })).sorted()
            let existing = try repository.fetchConversationState(service: card.service, conversationID: card.conversationId)

            let state = ConversationState(
                service: card.service,
                conversationId: card.conversationId,
                lastSeenMessageId: latestMessageID ?? existing?.lastSeenMessageId,
                lastSummarizedMessageId: latestMessageID ?? existing?.lastSummarizedMessageId,
                rollingSummary: card.summary,
                participants: participants.isEmpty ? existing?.participants : try encodeStringArray(participants),
                knownEntities: existing?.knownEntities,
                unresolvedActions: card.actionItems.isEmpty ? nil : try encodeStringArray(card.actionItems),
                lastBriefCardId: card.id,
                prioritySignals: #"{"priority":"\#(card.priority)"}"#,
                sourceMessageIds: try encodeStringArray(card.sourceMessageIds),
                updatedAt: now
            )
            try repository.upsertConversationState(state)
        }
    }

    private nonisolated func buildConversationBlock(
        service: String,
        conversationID: String,
        conversationTitle: String,
        newMessages: [Message],
        omittedNewMessageCount: Int,
        dateFormatter: DateFormatter,
        senderNameResolver: (String) -> String
    ) throws -> String {
        guard let firstNewMessageDate = newMessages.first?.timestamp else {
            return "=== [\(service)] \(conversationID) | \(conversationTitle) ==="
        }

        let state = try repository.fetchConversationState(service: service, conversationID: conversationID)
        let previousCard = try repository.fetchLatestBriefCard(service: service, conversationID: conversationID)
        let recentContext = try repository.fetchRecentContextMessages(
            service: service,
            conversationID: conversationID,
            before: firstNewMessageDate,
            since: firstNewMessageDate.addingTimeInterval(-recentContextWindow),
            limit: maxRecentContextMessages
        )

        // Header format: === [service] conversationID | conversationTitle ===
        // The [service] tag lets the LLM reliably extract service and conversationId
        // without guessing from the opaque ID format.
        var lines: [String] = ["=== [\(service)] \(conversationID) | \(conversationTitle) ==="]
        if let summary = state?.rollingSummary, !summary.isEmpty {
            lines.append("Previous summary: \(summary)")
        }
        if let previousHeadline = previousCard?.headline, !previousHeadline.isEmpty {
            lines.append("Previous brief card: \(previousHeadline)")
        }
        if let unresolved = state?.unresolvedActions, !unresolved.isEmpty {
            lines.append("Unresolved actions from prior brief: \(unresolved)")
        }
        if !recentContext.isEmpty {
            lines.append("[Recent context before new messages]")
            lines.append(contentsOf: recentContext.map { messageLine($0, dateFormatter: dateFormatter, senderNameResolver: senderNameResolver) })
        }
        if omittedNewMessageCount > 0 {
            lines.append("[\(omittedNewMessageCount) earlier new messages omitted]")
        }
        lines.append("[New messages]")
        lines.append(contentsOf: newMessages.map { messageLine($0, dateFormatter: dateFormatter, senderNameResolver: senderNameResolver) })
        return lines.joined(separator: "\n")
    }

    private nonisolated func messageLine(
        _ message: Message,
        dateFormatter: DateFormatter,
        senderNameResolver: (String) -> String
    ) -> String {
        "[id=\(message.messageId) | \(dateFormatter.string(from: message.timestamp))] \(senderNameResolver(message.sender)): \(message.text)"
    }

    private nonisolated func messageSortAscending(_ lhs: Message, _ rhs: Message) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.messageId != rhs.messageId {
            return lhs.messageId < rhs.messageId
        }
        return (lhs.id ?? 0) < (rhs.id ?? 0)
    }

    private nonisolated func repairJSON(_ text: String) -> String {
        var s = text
        // Remove trailing commas before ] or }
        s = s.replacingOccurrences(of: #",\s*\]"#, with: "]", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*\}"#, with: "}", options: .regularExpression)
        // Balance brackets if the LLM truncated the output
        let openBraces = s.filter { $0 == "{" }.count
        let closeBraces = s.filter { $0 == "}" }.count
        let openBrackets = s.filter { $0 == "[" }.count
        let closeBrackets = s.filter { $0 == "]" }.count
        if closeBraces < openBraces { s += String(repeating: "}", count: openBraces - closeBraces) }
        if closeBrackets < openBrackets { s += String(repeating: "]", count: openBrackets - closeBrackets) }
        return s
    }

    private nonisolated func stripMarkdownFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        return trimmed
            .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func encodeBriefJSON(_ briefJSON: BriefJSON) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(briefJSON)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private nonisolated func encodeStringArray(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
