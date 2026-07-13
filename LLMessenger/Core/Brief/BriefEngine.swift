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
    static let maximumAutomaticUserPromptTokens = 20_000
    static let maximumAutomaticJobsPerRun = 3
    static let maximumAutomaticCandidateMessages = 2_000
    static let maximumAutomaticJobMessages = 500
    private static let automaticNewMessageTokenBudget = 10_000
    private static let automaticContextTokenBudget = 4_000
    private static let maximumConversationsPerAutomaticJob = 30
    private static let automaticMetadataCharacterLimit = 200
    private let maxRecentContextMessages = 20
    private let recentContextWindow: TimeInterval = 24 * 3600
    /// Per-conversation budget for TokenEstimator.selectWithinBudget — replaces
    /// the old blind "last 100 messages" cap. ~3000 tokens roughly matches what
    /// 100 typical short chat messages cost, so ordinary threads see no change,
    /// while a thread of long messages now gets proportionally fewer of them
    /// instead of the same row count blowing past the model's context window.
    private let perConversationTokenBudget = 3000
    private let database: AppDatabase
    var client: LLMClient
    private let model: String
    private let basePrompt: String
    private let repository: BriefRepository
    private let now: @Sendable () -> Date
    private var briefingInFlight = false
    // Separate flag for manual summarizeLast requests — prevents duplicate briefs from
    // double-taps while still allowing summarizeLast to wait for and follow an auto-poll.
    private var summarizeLastInFlight = false

    init(
        database: AppDatabase,
        client: LLMClient,
        model: String,
        basePrompt: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.client = client
        self.model = model
        self.basePrompt = basePrompt
        self.repository = BriefRepository(database: database)
        self.now = now
    }

    @discardableResult
    func processNewMessages(adapters: [String: any MessengerAdapter] = [:]) async throws -> Int64? {
        guard !briefingInFlight else { return nil }
        briefingInFlight = true
        defer { briefingInFlight = false }

        // Compression is cycle-level work. Draining multiple immutable jobs must
        // not multiply this extra LLM call for every brief created in the cycle.
        if let previous = try repository.fetchOldestUncompressedBrief(), let previousID = previous.id {
            let compressor = MemoryCompressor(client: client, model: model, basePrompt: basePrompt)
            do {
                try await compressor.compress(briefID: previousID, repository: repository)
            } catch {
                try? repository.markCompressionFailed(briefID: previousID)
            }
        }

        var latestBriefID: Int64?
        var processedJobs = 0
        while processedJobs < Self.maximumAutomaticJobsPerRun,
              let outcome = try await processNextAutomaticBriefJob(adapters: adapters) {
            processedJobs += 1
            if let briefID = outcome.briefID {
                latestBriefID = briefID
            }
            guard outcome.jobCompleted else { break }
        }
        return latestBriefID
    }

    private struct AutomaticBriefOutcome {
        var briefID: Int64?
        var jobCompleted: Bool
    }

    /// Processes one immutable job snapshot. The public entry point drains a
    /// later snapshot only after this one fully succeeds; partial jobs wait for
    /// the next trigger instead of retrying a failed provider in a hot loop.
    private func processNextAutomaticBriefJob(
        adapters: [String: any MessengerAdapter]
    ) async throws -> AutomaticBriefOutcome? {

        let candidateMessages = try repository.fetchUnattachedMessages(
            limit: Self.maximumAutomaticCandidateMessages
        )

        // Privacy-excluded conversations never enter a durable job snapshot: a
        // cloud client must not persist work that it is not allowed to process.
        let clientIsCloud = self.client.isCloud
        let initiallyExcludedConversations: Set<String> = Set(
            Dictionary(grouping: candidateMessages, by: { $0.service }).flatMap { service, msgs in
                Set(msgs.map { $0.conversationId })
                    .filter { self.isExcludedByPrivacy(service: service, conversationId: $0, clientIsCloud: clientIsCloud) }
                    .map { "\(service)|\($0)" }
            }
        )
        let eligibleMessages = candidateMessages.filter {
            !initiallyExcludedConversations.contains("\($0.service)|\($0.conversationId)")
        }
        let selectedMessages = selectAutomaticJobMessages(eligibleMessages)
        guard let snapshot = try repository.claimAutomaticBriefJob(
            messages: selectedMessages,
            now: now(),
            messageLimit: Self.maximumAutomaticJobMessages
        ),
              let jobID = snapshot.job.id else { return nil }
        let snapshotMessages = selectAutomaticJobMessages(snapshot.messages)
        var jobFinalized = false
        defer {
            if !jobFinalized {
                try? repository.markBriefJobFailed(
                    jobID: jobID,
                    error: "Brief generation interrupted before commit",
                    now: now()
                )
            }
        }

        // Per-conversation privacy gate: conversations the user marked never_draft (no LLM
        // ever) or local_only (cloud client only) are excluded from the brief entirely. Their
        // text must never enter threadText, and their messages must stay unattached so they
        // are not lost. Keys are "service|conversationId" (same convention as elsewhere).
        let excludedConversations: Set<String> = Set(
            Dictionary(grouping: snapshotMessages, by: { $0.service }).flatMap { service, msgs in
                Set(msgs.map { $0.conversationId })
                    .filter { self.isExcludedByPrivacy(service: service, conversationId: $0, clientIsCloud: clientIsCloud) }
                    .map { "\(service)|\($0)" }
            }
        )
        let privacyExcludedMessages = snapshotMessages.filter {
            excludedConversations.contains("\($0.service)|\($0.conversationId)")
        }
        if !privacyExcludedMessages.isEmpty {
            _ = try repository.skipBriefJobMessages(
                jobID: jobID,
                messages: privacyExcludedMessages,
                now: now()
            )
        }
        let messages = snapshotMessages.filter {
            !excludedConversations.contains("\($0.service)|\($0.conversationId)")
        }
        if messages.isEmpty {
            jobFinalized = true
            return AutomaticBriefOutcome(briefID: nil, jobCompleted: true)
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
        var succeededMessages: [Message] = []

        struct ServiceResult {
            let service: String
            let cards: [BriefCard]
            let stats: (messages: Int, threads: Int, people: Int)
            let sourceMessages: [String: Message]
            let succeededMessages: [Message]
            let hadFailures: Bool
        }

        // Snapshot @MainActor properties before entering the task group so child tasks
        // use a stable copy and don't race on the `var client` property.
        let client = self.client
        let model = self.model
        let basePrompt = self.basePrompt
        let briefLanguage = SettingsRepository().loadBriefLanguage()
        let automaticContextTokenBudget = Self.automaticContextTokenBudget
        let automaticMetadataCharacterLimit = Self.automaticMetadataCharacterLimit
        let maximumAutomaticUserPromptTokens = Self.maximumAutomaticUserPromptTokens

        let results = await withTaskGroup(of: ServiceResult?.self) { group in
            for service in services {
                let serviceMessages = messagesByService[service] ?? []
                let recent = (try? repository.recentEpisodicSummaries(service: service, limit: 3)) ?? []
                let signalAdapter = adapters[service] as? SignalCLIAdapter

                group.addTask {
                    do {
                        let byConversation: [String: [Message]] = Dictionary(grouping: serviceMessages, by: { $0.conversationId })
                            .filter { convId, _ in !excludedConversations.contains("\(service)|\(convId)") }
                        let contexts = byConversation.keys.compactMap {
                            try? self.repository.fetchConversationContext(service: service, conversationId: $0)
                        }
                        let systemPrompt = PromptBuilder.build(
                            mode: .summarizer,
                            basePrompt: basePrompt,
                            services: [service],
                            episodicSummaries: recent,
                            now: Date(),
                            conversationContexts: contexts,
                            briefLanguage: briefLanguage
                        )
                        let rankedConvIds = byConversation.keys
                            .sorted {
                                let lhsDate = byConversation[$0]?.map(\.timestamp).min() ?? .distantFuture
                                let rhsDate = byConversation[$1]?.map(\.timestamp).min() ?? .distantFuture
                                return lhsDate == rhsDate ? $0 < $1 : lhsDate < rhsDate
                            }

                        var conversationBlocks: [String] = []
                        // Collect context messages so their IDs are valid in decodeAndValidateBrief.
                        // buildConversationBlock prepends recentContext messages to the prompt —
                        // if the LLM cites one of those IDs in sourceMessageIds, it must be in
                        // the allowlist, otherwise every card in an active conversation gets rejected.
                        var allPromptMessages: [Message] = serviceMessages
                        let contextBudgetPerConversation = automaticContextTokenBudget
                            / max(1, rankedConvIds.count)
                        for convId in rankedConvIds {
                            let convMessages = (byConversation[convId] ?? []).sorted { $0.timestamp < $1.timestamp }
                            let firstDate = convMessages.first?.timestamp ?? Date()
                            let rawContextMessages = (try? self.repository.fetchRecentContextMessages(
                                service: service,
                                conversationID: convId,
                                before: firstDate,
                                since: firstDate.addingTimeInterval(-self.recentContextWindow),
                                limit: self.maxRecentContextMessages
                            )) ?? []
                            let contextMessages = TokenEstimator.selectWithinBudget(
                                rawContextMessages,
                                tokenBudget: contextBudgetPerConversation,
                                text: \.text
                            )
                            allPromptMessages.append(contentsOf: contextMessages)

                            let convHeader = convMessages.first?.conversationName
                                ?? signalAdapter?.groupName(for: convId)
                                ?? signalAdapter?.contactName(for: convId)
                                ?? convId
                            let block = try self.buildConversationBlock(
                                service: service,
                                conversationID: convId,
                                conversationTitle: convHeader,
                                newMessages: convMessages,
                                omittedNewMessageCount: 0,
                                recentContextMessages: contextMessages,
                                metadataCharacterLimit: automaticMetadataCharacterLimit,
                                dateFormatter: dateFormatter,
                                senderNameResolver: { sender in
                                    let resolved = signalAdapter?.contactName(for: sender)
                                    return resolved ?? (sender.count > 20 ? "Unknown" : sender)
                                }
                            )
                            conversationBlocks.append(block)
                        }
                        // Every conversation for this service was excluded by the privacy gate —
                        // make no LLM call (an empty prompt would send nothing useful to the cloud).
                        guard !conversationBlocks.isEmpty else { return nil }
                        let threadText = conversationBlocks.joined(separator: "\n\n")
                        guard TokenEstimator.estimate(threadText) <= maximumAutomaticUserPromptTokens else {
                            return ServiceResult(
                                service: service,
                                cards: [],
                                stats: (0, 0, 0),
                                sourceMessages: [:],
                                succeededMessages: [],
                                hadFailures: true
                            )
                        }

                        let response = try await client.complete(
                            model: model,
                            messages: [
                                LLMMessage(role: .system, content: systemPrompt),
                                LLMMessage(role: .user,   content: threadText)
                            ],
                            maxTokens: 4000
                        )

                        if let parsed = try? self.decodeAndValidateBrief(response.text, service: service, sourceMessages: allPromptMessages) {
                            let coveredConversations = Set(parsed.cards.map(\.conversationId))
                            let coveredMessages = serviceMessages.filter {
                                coveredConversations.contains($0.conversationId)
                            }
                            let sourceMessages = Dictionary(
                                allPromptMessages.map { ($0.messageId, $0) },
                                uniquingKeysWith: { first, _ in first }
                            )
                            return ServiceResult(
                                service: service,
                                cards: parsed.cards,
                                stats: (
                                    coveredMessages.count,
                                    coveredConversations.count,
                                    Set(coveredMessages.map(\.sender)).count
                                ),
                                sourceMessages: sourceMessages,
                                succeededMessages: coveredMessages,
                                hadFailures: coveredMessages.count != serviceMessages.count
                            )
                        } else {
                            return ServiceResult(
                                service: service,
                                cards: [],
                                stats: (0, 0, 0),
                                sourceMessages: [:],
                                succeededMessages: [],
                                hadFailures: true
                            )
                        }
                    } catch {
                        return ServiceResult(
                            service: service,
                            cards: [],
                            stats: (0, 0, 0),
                            sourceMessages: [:],
                            succeededMessages: [],
                            hadFailures: true
                        )
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
            if !res.succeededMessages.isEmpty {
                parsedServices.insert(res.service)
                sourceMessagesByService[res.service] = res.sourceMessages
                succeededMessages.append(contentsOf: res.succeededMessages)
                totalMessages += res.stats.messages
                totalThreads += res.stats.threads
                totalPeople += res.stats.people
                allCards.append(contentsOf: res.cards)
            }
            if res.hadFailures {
                failedServices.insert(res.service)
            }
        }

        // Step 4: Guard against blank briefs — messages stay unattached if LLM returned nothing.
        guard !allCards.isEmpty else {
            try repository.markBriefJobFailed(
                jobID: jobID,
                error: "No valid cards were generated",
                now: now()
            )
            jobFinalized = true
            return nil
        }

        allCards = applyPriorityRules(to: allCards)

        // Context-aware ordering: surface high-priority-context conversations first and push
        // low/noise-dominated ones to the end. Pure helper; falls back to LLM priority when no
        // context overrides exist.
        let cardContexts = allCards.compactMap {
            try? repository.fetchConversationContext(service: $0.service, conversationId: $0.conversationId)
        }
        allCards = DigestOrdering.order(cards: allCards, contexts: cardContexts).map { $0.card.withCollapsed($0.collapsed) }

        let merged = BriefJSON(
            totalMessages: totalMessages,
            totalThreads: totalThreads,
            totalPeople: totalPeople,
            cards: allCards
        )
        let openingSummary = try encodeBriefJSON(merged)

        // Step 5: Create the Brief and attach messages
        let notificationText = "\(succeededMessages.count) new messages · \(Array(parsedServices).sorted().joined(separator: ", "))"
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
        // Completion is conversation-exact: only messages from conversations
        // represented by a validated card are attached. Omitted conversations
        // remain pending in the durable job for a later retry.
        let messagesToAttach = succeededMessages

        // Build record arrays on the main actor before entering the transaction closure.
        let (cardRecords, cardSources) = try buildBriefCardRecords(
            allCards, briefID: 0, sourceMessagesByService: sourceMessagesByService
        )
        let failedServicesSnapshot = failedServices

        // Atomic transaction: Brief row + all cards + all sources + message attachment.
        // If any step throws, the entire transaction rolls back — no partial brief is committed.
        let briefID = try await database.dbQueue.write { db in
            let insertedID = try BriefRepository.insertBrief(brief, db: db)
            // Re-stamp briefId now that we have a real ID.
            let stampedCards = cardRecords.map { card -> BriefCardRecord in
                var c = card
                c.briefId = insertedID
                return c
            }
            let stampedSources = cardSources  // briefCardId is already the UUID; no re-stamp needed
            try BriefRepository.insertBriefCardsBatch(stampedCards, db: db)
            try BriefRepository.insertBriefCardSources(stampedSources, db: db)
            try BriefRepository.insertTasksForCards(stampedCards, db: db)
            try BriefRepository.attach(messages: messagesToAttach, toBriefID: insertedID, db: db)
            try BriefRepository.completeBriefJob(
                jobID: jobID,
                messages: messagesToAttach,
                briefID: insertedID,
                failedServices: failedServicesSnapshot,
                now: self.now(),
                db: db
            )
            return insertedID
        }
        jobFinalized = true

        try persistConversationStates(allCards, sourceMessagesByService: sourceMessagesByService)
        updateContactProfiles(from: allCards)

        return AutomaticBriefOutcome(
            briefID: briefID,
            jobCompleted: failedServicesSnapshot.isEmpty
        )
    }

    // Fetch from adapters for the last N hours, store any new messages, and create a brief.
    @discardableResult
    func summarizeLast(hours: Int, adapters: [String: any MessengerAdapter]) async throws -> Int64? {
        // Dedup concurrent manual requests (e.g. double-tap).
        guard !summarizeLastInFlight else { return nil }
        summarizeLastInFlight = true
        defer { summarizeLastInFlight = false }

        // Wait up to 60s for an in-flight auto-poll brief to finish before running.
        var waited = 0
        while briefingInFlight && waited < 60 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
        guard !briefingInFlight else { return nil }
        briefingInFlight = true
        defer { briefingInFlight = false }

        // Compress oldest uncompressed brief before creating a new one (same as processNewMessages).
        if let prev = try repository.fetchOldestUncompressedBrief(), let prevID = prev.id {
            let compressor = MemoryCompressor(client: client, model: model, basePrompt: basePrompt)
            do {
                try await compressor.compress(briefID: prevID, repository: repository)
            } catch {
                try? repository.markCompressionFailed(briefID: prevID)
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

        // Snapshot @MainActor properties before entering the task group.
        let client2 = self.client
        let model2 = self.model
        let basePrompt2 = self.basePrompt
        let briefLanguage2 = SettingsRepository().loadBriefLanguage()

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
                            // Fetch ALL messages in the window PLUS the 24h context window that
                            // buildConversationBlock prepends before the first new message.
                            // Without this, the LLM can reference context message IDs that are
                            // outside 'since' and decodeAndValidateBrief rejects the whole service.
                            let sourceSince = since.addingTimeInterval(-self.recentContextWindow)
                            sourceMessages = try self.repository.fetchMessages(service: serviceID, since: sourceSince)
                            // Only show the LLM messages that haven't been briefed yet.
                            // Already-briefed messages become recentContext via buildConversationBlock;
                            // showing them as "new" causes the LLM to re-create the same cards.
                            let briefedIDs = Set(sourceMessages.filter { $0.briefId != nil }.map(\.messageId))
                            let filteredConvs = result.conversations.compactMap { conv -> AdapterConversation? in
                                let fresh = conv.messages.filter { !briefedIDs.contains($0.id) }
                                guard !fresh.isEmpty else { return nil }
                                return AdapterConversation(id: conv.id, name: conv.name, type: conv.type, messages: fresh)
                            }
                            guard !filteredConvs.isEmpty else { return nil }
                            conversations = filteredConvs
                        } else {
                            // Adapter unavailable or empty — use messages already stored by the poll loop.
                            let sourceSince = since.addingTimeInterval(-self.recentContextWindow)
                            let dbMessages = try self.repository.fetchMessages(service: serviceID, since: sourceSince)
                            // Only attach unattached messages; already-briefed ones are included
                            // in sourceMessages for validation but must not have their briefId
                            // reassigned to this new brief.
                            let unattached = dbMessages.filter { $0.timestamp > since && $0.briefId == nil }
                            let dbCount = unattached.count
                            print("[BriefEngine] \(serviceID): using DB fallback, \(dbCount) unattached messages in window (adapter: \(adapterResult == nil ? "nil" : "empty"))")
                            guard !unattached.isEmpty else { return nil }
                            newlyStored = unattached
                            sourceMessages = dbMessages
                            // Build conversations from unattached messages only so the LLM sees
                            // only what hasn't been briefed yet.
                            var byConv: [String: [Message]] = [:]
                            for m in unattached { byConv[m.conversationId, default: []].append(m) }
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

                        // Per-conversation privacy gate: drop conversations marked never_draft
                        // (no LLM ever) or local_only while the client is a cloud provider, BEFORE
                        // any text reaches the prompt. Their newly-stored messages are filtered out
                        // of the attach set below so they stay unattached rather than being lost.
                        let isCloud = client2.isCloud
                        let excludedIDs = Set(conversations.map { $0.id }).filter {
                            self.isExcludedByPrivacy(service: serviceID, conversationId: $0, clientIsCloud: isCloud)
                        }
                        let allowedConversations = conversations.filter { !excludedIDs.contains($0.id) }
                        guard !allowedConversations.isEmpty else { return nil }
                        let attachableNewlyStored = newlyStored.filter { !excludedIDs.contains($0.conversationId) }

                        let recent = try self.repository.recentEpisodicSummaries(service: serviceID, limit: 3)
                        let corrections = (try? self.repository.fetchRecentPriorityCorrections(limit: 6)) ?? []
                        let correctionTuples = corrections.map {
                            (headline: $0.cardHeadline, llmPriority: $0.llmPriority, userPriority: $0.userPriority)
                        }
                        let contexts = Set(allowedConversations.map { $0.id }).compactMap {
                            try? self.repository.fetchConversationContext(service: serviceID, conversationId: $0)
                        }
                        let systemPrompt = PromptBuilder.build(
                            mode: .summarizer,
                            basePrompt: basePrompt2,
                            services: [serviceID],
                            episodicSummaries: recent,
                            now: Date(),
                            priorityCorrections: correctionTuples,
                            conversationContexts: contexts,
                            briefLanguage: briefLanguage2
                        )

                        var conversationBlocks: [String] = []
                        var msgCount = 0
                        for conv in allowedConversations {
                            let sorted = conv.messages.sorted { $0.timestamp < $1.timestamp }
                            let capped = TokenEstimator.selectWithinBudget(
                                sorted, tokenBudget: self.perConversationTokenBudget, text: \.text)
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

                        let response = try await client2.complete(
                            model: model2,
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
                                newlyStored: attachableNewlyStored,
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

        allCards = applyPriorityRules(to: allCards)

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
        // Build record arrays on the main actor before entering the transaction closure.
        let (cardRecords2, cardSources2) = try buildBriefCardRecords(
            allCards, briefID: 0, sourceMessagesByService: sourceMessagesByService
        )

        // Capture messagesToAttach in a local let so the @Sendable write closure can capture it.
        let messagesToAttachSnapshot = messagesToAttach

        // Atomic transaction: Brief row + all cards + all sources + message attachment.
        let briefID = try await database.dbQueue.write { db in
            let insertedID = try BriefRepository.insertBrief(brief, db: db)
            let stampedCards = cardRecords2.map { card -> BriefCardRecord in
                var c = card
                c.briefId = insertedID
                return c
            }
            try BriefRepository.insertBriefCardsBatch(stampedCards, db: db)
            try BriefRepository.insertBriefCardSources(cardSources2, db: db)
            try BriefRepository.insertTasksForCards(stampedCards, db: db)
            if !messagesToAttachSnapshot.isEmpty {
                try BriefRepository.attach(messages: messagesToAttachSnapshot, toBriefID: insertedID, db: db)
            }
            return insertedID
        }

        try persistConversationStates(allCards, sourceMessagesByService: sourceMessagesByService)
        updateContactProfiles(from: allCards)

        return briefID
    }

    private nonisolated func decodeAndValidateBrief(_ text: String, service: String, sourceMessages: [Message]) throws -> BriefJSON {
        let cleanText = BriefJSON.extractJSONPayload(from: text)
        guard let data = cleanText.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8"))
        }
        let parsed = try JSONDecoder().decode(BriefJSON.self, from: data)
        guard !parsed.cards.isEmpty else { throw BriefEngineValidationError.emptyCards }

        let sourceMessagesByID = Dictionary(
            sourceMessages.map { ($0.messageId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var validCards: [BriefCard] = []
        for card in parsed.cards {
            guard card.service == service else {
                print("[BriefEngine] skipping card \(card.id): wrong service \(card.service)")
                continue
            }

            let validSourceIDs = card.sourceMessageIds.filter { messageID in
                guard !messageID.isEmpty, let source = sourceMessagesByID[messageID] else { return false }
                return source.conversationId == card.conversationId
            }
            let droppedCount = card.sourceMessageIds.count - validSourceIDs.count
            if droppedCount > 0 {
                print("[BriefEngine] card \(card.id): dropped \(droppedCount) unknown sourceMessageIds")
            }
            guard !validSourceIDs.isEmpty else {
                print("[BriefEngine] skipping card \(card.id): no valid sourceMessageIds")
                continue
            }

            let validQuotes = card.quotes.filter { q in
                guard let mid = q.messageId, let source = sourceMessagesByID[mid] else { return false }
                return source.conversationId == card.conversationId
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
                needsReply: card.needsReply,
                reason: card.reason,
                grounding: card.grounding,
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

    /// Builds card records and source records in memory. Called inside the atomic transaction.
    private nonisolated func buildBriefCardRecords(
        _ cards: [BriefCard],
        briefID: Int64,
        sourceMessagesByService: [String: [String: Message]]
    ) throws -> (cardRecords: [BriefCardRecord], sources: [BriefCardSource]) {
        let now = Date()
        var cardRecords: [BriefCardRecord] = []
        var allSources: [BriefCardSource] = []

        for card in cards {
            // Always generate a fresh UUID — the LLM-produced card.id is reused across
            // brief runs for the same conversation, causing UNIQUE constraint failures.
            let cardID = UUID().uuidString

            // Validate before adding — mirrors the guard inside insertBriefCard.
            guard !card.sourceMessageIds.isEmpty else {
                print("[BriefEngine] buildBriefCardRecords: skipping card \(cardID) (\(card.service)/\(card.conversationId)): no source message IDs")
                continue
            }

            let record = BriefCardRecord(
                id: cardID,
                briefId: briefID,
                service: card.service,
                conversationId: card.conversationId,
                conversationTitle: card.conversationTitle,
                headline: card.headline,
                priority: card.priority,
                summary: card.summary,
                needsReply: card.needsReply,
                reason: card.reason,
                grounding: card.grounding,
                actionItems: try encodeStringArray(card.actionItems),
                callbackText: card.callback,
                sourceMessageIds: try encodeStringArray(card.sourceMessageIds),
                createdAt: now
            )

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

            cardRecords.append(record)
            allSources.append(contentsOf: sources)
        }

        return (cardRecords, allSources)
    }

    private func persistConversationStates(
        _ cards: [BriefCard],
        sourceMessagesByService: [String: [String: Message]]
    ) throws {
        let now = Date()
        // Group cards by conversation. The LLM is instructed to emit one card per
        // conversationId, but may produce duplicates. Grouping here ensures we write
        // exactly one ConversationState per conversation, merging data from all cards
        // rather than silently clobbering earlier cards with later ones.
        let grouped: [String: [BriefCard]] = Dictionary(
            grouping: cards,
            by: { "\($0.service)|\($0.conversationId)" }
        )
        for (_, convCards) in grouped {
            guard let firstCard = convCards.first else { continue }
            let service = firstCard.service
            let convId = firstCard.conversationId

            let serviceMessages = sourceMessagesByService[service].map { Array($0.values) } ?? []
            let conversationMessages = serviceMessages
                .filter { $0.conversationId == convId }
                .sorted(by: messageSortAscending)
            let latestMessageID = conversationMessages.last?.messageId
            let participants = Array(Set(conversationMessages.map { $0.sender })).sorted()
            let existing = try repository.fetchConversationState(service: service, conversationID: convId)

            // Merge action items from all cards, preserving order and deduplicating.
            var allActionItems: [String] = []
            var seenActions = Set<String>()
            for card in convCards {
                for item in card.actionItems where seenActions.insert(item).inserted {
                    allActionItems.append(item)
                }
            }

            // Merge summaries: single card uses its summary directly; multiple cards
            // are joined so no context is discarded.
            let mergedSummary = convCards.count == 1
                ? firstCard.summary
                : convCards.map(\.summary).joined(separator: "\n")

            // Merge source message IDs from all cards (deduplicated, order-preserving).
            var allSourceIDs: [String] = []
            var seenIDs = Set<String>()
            for card in convCards {
                for id in card.sourceMessageIds where seenIDs.insert(id).inserted {
                    allSourceIDs.append(id)
                }
            }

            // Highest priority wins when cards disagree.
            let priority = convCards.map(\.priority).min(by: { priorityRank($0) < priorityRank($1) })
                ?? firstCard.priority
            let safePriority = ["high", "medium", "med", "low"].contains(priority.lowercased()) ? priority.lowercased() : "low"
            let lastCardId = convCards.last?.id ?? firstCard.id

            let state = ConversationState(
                service: service,
                conversationId: convId,
                lastSeenMessageId: latestMessageID ?? existing?.lastSeenMessageId,
                lastSummarizedMessageId: latestMessageID ?? existing?.lastSummarizedMessageId,
                rollingSummary: mergedSummary,
                participants: participants.isEmpty ? existing?.participants : try encodeStringArray(participants),
                knownEntities: existing?.knownEntities,
                unresolvedActions: allActionItems.isEmpty ? nil : try encodeStringArray(allActionItems),
                lastBriefCardId: lastCardId,
                prioritySignals: #"{"priority":"\#(safePriority)"}"#,
                sourceMessageIds: try encodeStringArray(allSourceIDs),
                updatedAt: now
            )
            try repository.upsertConversationState(state)
        }
    }

    private nonisolated func priorityRank(_ priority: String) -> Int {
        switch priority {
        case "high":            return 0
        case "med", "medium":   return 1
        case "low":             return 2
        default:                return 3
        }
    }

    /// Selects a bounded, oldest-first input slice. Only selected rows enter a
    /// new durable job, so every row owned by that job is present in its prompt.
    private func selectAutomaticJobMessages(_ messages: [Message]) -> [Message] {
        var selected: [Message] = []
        let byService = Dictionary(grouping: messages, by: \.service)

        for service in byService.keys.sorted() {
            let serviceMessages = byService[service] ?? []
            let byConversation = Dictionary(grouping: serviceMessages, by: \.conversationId)
            let conversationIDs = byConversation.keys.sorted { lhs, rhs in
                let lhsDate = byConversation[lhs]?.map(\.timestamp).min() ?? .distantFuture
                let rhsDate = byConversation[rhs]?.map(\.timestamp).min() ?? .distantFuture
                return lhsDate == rhsDate ? lhs < rhs : lhsDate < rhsDate
            }

            var serviceTokens = 0
            var selectedConversations = 0
            for conversationID in conversationIDs {
                guard selectedConversations < Self.maximumConversationsPerAutomaticJob,
                      selected.count < Self.maximumAutomaticJobMessages else { break }

                let conversationMessages = (byConversation[conversationID] ?? [])
                    .sorted(by: messageSortAscending)
                var conversationTokens = 0
                var conversationSelection: [Message] = []
                for message in conversationMessages {
                    guard selected.count + conversationSelection.count < Self.maximumAutomaticJobMessages else { break }
                    let cost = TokenEstimator.estimate(message.text)
                    let fitsConversation = conversationTokens + cost <= perConversationTokenBudget
                    let fitsService = serviceTokens + conversationTokens + cost
                        <= Self.automaticNewMessageTokenBudget
                    if fitsConversation && fitsService {
                        conversationSelection.append(message)
                        conversationTokens += cost
                    } else if conversationSelection.isEmpty && selectedConversations == 0 {
                        // One oversized message still has to make progress. The final
                        // prompt guard prevents accidental multi-message overflow.
                        conversationSelection.append(message)
                        conversationTokens += cost
                    } else {
                        break
                    }
                }

                guard !conversationSelection.isEmpty else { break }
                selected.append(contentsOf: conversationSelection)
                serviceTokens += conversationTokens
                selectedConversations += 1
            }
        }

        return selected.sorted(by: messageSortAscending)
    }

    /// Per-conversation privacy gate shared by both brief paths. A conversation is
    /// excluded from the brief — its message text never reaches the LLM — when it is
    /// marked never_draft (no LLM ever) or local_only while the client is a cloud
    /// provider. Mirrors CommitmentDeriver.derive and AgentEngine.proposeReply.
    private nonisolated func isExcludedByPrivacy(service: String, conversationId: String, clientIsCloud: Bool) -> Bool {
        let ctx = (try? repository.fetchConversationContext(service: service, conversationId: conversationId)) ?? nil
        if ctx?.privacyOverride == "never_draft" { return true }
        if ctx?.privacyOverride == "local_only", clientIsCloud { return true }
        return false
    }

    private nonisolated func buildConversationBlock(
        service: String,
        conversationID: String,
        conversationTitle: String,
        newMessages: [Message],
        omittedNewMessageCount: Int,
        recentContextMessages: [Message]? = nil,
        metadataCharacterLimit: Int? = nil,
        dateFormatter: DateFormatter,
        senderNameResolver: (String) -> String
    ) throws -> String {
        func bounded(_ value: String) -> String {
            let sanitized = value.replacingOccurrences(of: "===", with: "—")
            guard let metadataCharacterLimit, sanitized.count > metadataCharacterLimit else {
                return sanitized
            }
            return String(sanitized.prefix(metadataCharacterLimit))
        }

        // Sanitize user-supplied strings to prevent delimiter spoofing in the structured prompt.
        let safeConvID = bounded(conversationID)
        let safeTitle = bounded(conversationTitle)

        guard let firstNewMessageDate = newMessages.first?.timestamp else {
            return "=== [\(service)] \(safeConvID) | \(safeTitle) ==="
        }

        let state = try repository.fetchConversationState(service: service, conversationID: conversationID)
        let previousCard = try repository.fetchLatestBriefCard(service: service, conversationID: conversationID)
        let recentContext: [Message]
        if let recentContextMessages {
            recentContext = recentContextMessages
        } else {
            recentContext = try repository.fetchRecentContextMessages(
                service: service,
                conversationID: conversationID,
                before: firstNewMessageDate,
                since: firstNewMessageDate.addingTimeInterval(-recentContextWindow),
                limit: maxRecentContextMessages
            )
        }

        // Header format: === [service] conversationID | conversationTitle ===
        // The [service] tag lets the LLM reliably extract service and conversationId
        // without guessing from the opaque ID format.
        var lines: [String] = ["=== [\(service)] \(safeConvID) | \(safeTitle) ==="]

        // Inject user-defined relationship context (label + priority hint).
        // Sanitize both fields: a crafted label like "=== [signal] … ===" would inject
        // a fake conversation block header into the structured prompt.
        if let ctx = try? repository.fetchConversationContext(service: service, conversationId: conversationID) {
            var ctxParts: [String] = []
            if !ctx.label.isEmpty {
                ctxParts.append(bounded(ctx.label))
            }
            if ctx.priorityHint != "auto" {
                ctxParts.append("priority override: \(bounded(ctx.priorityHint))")
            }
            if !ctxParts.isEmpty {
                lines.append("Context: \(ctxParts.joined(separator: " · "))")
            }
        }

        if let summary = state?.rollingSummary, !summary.isEmpty {
            lines.append("Previous summary: \(bounded(summary))")
        }
        if let previousHeadline = previousCard?.headline, !previousHeadline.isEmpty {
            lines.append("Previous brief card: \(bounded(previousHeadline))")
        }
        if let unresolved = state?.unresolvedActions, !unresolved.isEmpty {
            lines.append("Unresolved actions from prior brief: \(bounded(unresolved))")
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
        // [YOU] marks your own sent messages so the LLM can detect reply state and assign
        // priority correctly — threads where YOU sent last are rarely urgent.
        let senderLabel = message.isSent ? "YOU" : senderNameResolver(message.sender)
        // Sanitize message text to prevent delimiter spoofing.
        let safeText = message.text.replacingOccurrences(of: "===", with: "—")
        return "[id=\(message.messageId) | \(dateFormatter.string(from: message.timestamp))] \(senderLabel): \(safeText)"
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

    // MARK: - Priority Rules

    private func applyPriorityRules(to cards: [BriefCard]) -> [BriefCard] {
        let rules = (try? database.dbQueue.read { db in try PriorityRule.fetchAll(db) }) ?? []
        guard !rules.isEmpty else { return cards }
        return cards.map { card in
            let contactName = card.conversationTitle ?? card.conversationId
            let messageText = card.headline + " " + card.summary
            guard let match = RuleEvaluator.evaluate(
                contactName: contactName,
                service: card.service,
                messageText: messageText,
                rules: rules
            ) else { return card }

            let newPriority: String
            let needsReply: Bool
            let reason: String
            switch match.action {
            case .alwaysNotify:
                newPriority = "high"
                needsReply = true
                reason = "Rule: always notify"
                print("[BriefEngine] rule overrides card \(card.id) → high (alwaysNotify)")
            case .suppress:
                newPriority = "low"
                needsReply = false
                reason = "Rule: suppressed"
                print("[BriefEngine] rule overrides card \(card.id) → low (suppress)")
            case .setPriority(let p):
                newPriority = p
                needsReply = card.needsReply
                reason = "Rule: priority set to \(p)"
                print("[BriefEngine] rule sets card \(card.id) → \(p)")
            }
            return card.withActionability(priority: newPriority,
                                          needsReply: needsReply,
                                          reason: reason)
        }
    }

    // MARK: - Contact Profile Updates

    private func updateContactProfiles(from cards: [BriefCard]) {
        for card in cards {
            let displayName = card.conversationTitle ?? card.conversationId
            let profile = ContactProfile(
                id: nil,
                service: card.service,
                conversationId: card.conversationId,
                displayName: displayName,
                notes: nil,
                lastTopics: card.headline,
                pendingAsk: card.actionItems.first,
                updatedAt: Date()
            )
            try? database.dbQueue.write { db in
                try profile.upsert(db)
            }
        }
    }

    // MARK: - Proactive Draft Staging

    func checkProactiveDrafts() async {
        let cutoff = Date().addingTimeInterval(-4 * 3600)
        let candidates: [BriefCardRecord]
        do {
            candidates = try await database.dbQueue.read { db in
                try BriefCardRecord
                    .filter(Column("priority") == "high")
                    .filter(Column("createdAt") < cutoff)
                    .fetchAll(db)
            }
        } catch {
            print("[BriefEngine] checkProactiveDrafts: DB read failed: \(error)")
            return
        }

        for card in candidates {
            let displayName = card.conversationTitle ?? card.conversationId
            NotificationManager.postDraftReadyNotification(senderName: displayName, briefID: card.briefId)
        }
    }
}
