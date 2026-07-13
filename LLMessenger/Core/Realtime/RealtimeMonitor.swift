// LLMessenger/Core/Realtime/RealtimeMonitor.swift
import Foundation
import GRDB

actor RealtimeMonitor {
    private let adapters: [String: any MessengerAdapter]
    private let db: AppDatabase
    private let ingestionCoordinator: MessageIngestionCoordinator
    private let triageEngine: TriageEngine
    private let rulesProvider: @Sendable () async -> [PriorityRule]

    private var running = false
    private var pollTasks: [Task<Void, Never>] = []
    private var fsSource: DispatchSourceFileSystemObject?
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var pendingMessages: [String: [String: Message]] = [:]
    private var pendingConversationNames: [String: String] = [:]

    var isRunning: Bool { running }

    /// Real-time firewall poll cadence for non-iMessage services (iMessage uses FSEvents and
    /// is event-driven, so it is unaffected). Configurable via UserDefaults; default 60s. Each
    /// tick may spawn a signal-cli/telegram subprocess, so this is the main background-CPU knob
    /// for polled services.
    /// ponytail: deliberately NOT coalesced into PollEngine — that polls on the ~15min brief
    /// cadence (pollIntervalSeconds default 900), so folding triage into it would slow the
    /// firewall to 15min. The firewall stays a separate, faster loop; raise this interval if
    /// background CPU matters more than sub-minute urgency latency.
    private static var pollIntervalSeconds: TimeInterval {
        let configured = UserDefaults.standard.integer(forKey: "realtimePollIntervalSeconds")
        return TimeInterval(configured > 0 ? configured : 60)
    }

    private static let walPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db-wal").path

    init(
        adapters: [String: any MessengerAdapter],
        db: AppDatabase,
        ingestionCoordinator: MessageIngestionCoordinator,
        notificationManager: NotificationManager,
        llmClient: any LLMClient,
        llmModel: String,
        rulesProvider: @escaping @Sendable () async -> [PriorityRule]
    ) {
        self.adapters = adapters
        self.db = db
        self.ingestionCoordinator = ingestionCoordinator
        self.triageEngine = TriageEngine(
            db: db,
            llmClient: llmClient,
            llmModel: llmModel,
            notificationManager: notificationManager
        )
        self.rulesProvider = rulesProvider
    }

    func start() async {
        guard !running else { return }
        guard !UserDefaults.standard.bool(forKey: "realtimeFirewallDisabled") else { return }
        running = true
        await ingestionCoordinator.setNewMessagesHandler { [weak self] messages in
            await self?.receiveNewMessages(messages)
        }
        await enqueuePendingUntriagedMessages()

        // iMessage: FSEvents on WAL file
        if let iMessageAdapter = adapters["imessage"],
           FileManager.default.fileExists(atPath: Self.walPath) {
            startFSWatch(adapter: iMessageAdapter)
        } else if let iMessageAdapter = adapters["imessage"] {
            // FDA not granted — fall back to 30s poll
            startPollTask(serviceID: "imessage", adapter: iMessageAdapter)
        }

        // Non-iMessage adapters: 30s poll
        for (serviceID, adapter) in adapters where serviceID != "imessage" {
            startPollTask(serviceID: serviceID, adapter: adapter)
        }
    }

    func stop() async {
        running = false
        fsSource?.cancel()
        fsSource = nil
        for task in pollTasks { task.cancel() }
        pollTasks.removeAll()
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks.removeAll()
        pendingMessages.removeAll()
        pendingConversationNames.removeAll()
        await ingestionCoordinator.setNewMessagesHandler(nil)
    }

    // MARK: - FSWatch

    private func startFSWatch(adapter: any MessengerAdapter) {
        let fd = open(Self.walPath, O_EVTONLY)
        guard fd >= 0 else {
            startPollTask(serviceID: "imessage", adapter: adapter)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.onWALWrite(adapter: adapter) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fsSource = source
    }

    private func onWALWrite(adapter: any MessengerAdapter) async {
        guard running else { return }
        let since = Date().addingTimeInterval(-60)
        let config = FetchConfig(mode: .byTime(since: since))
        _ = try? await ingestionCoordinator.ingest(
            service: "imessage",
            adapter: adapter,
            config: config
        )
    }

    // MARK: - Poll

    private func startPollTask(serviceID: String, adapter: any MessengerAdapter) {
        let task = Task.detached { [weak self] in
            while true {
                guard let strongSelf = self, await strongSelf.isRunning else { return }
                guard !UserDefaults.standard.bool(forKey: "realtimeFirewallDisabled") else { return }
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
                guard let strongSelf2 = self, await strongSelf2.isRunning else { return }
                await strongSelf2.pollAdapter(serviceID: serviceID, adapter: adapter)
            }
        }
        pollTasks.append(task)
    }

    private func pollAdapter(serviceID: String, adapter: any MessengerAdapter) async {
        // Look back one full interval plus a 5s overlap so no message slips between ticks.
        let since = Date().addingTimeInterval(-(Self.pollIntervalSeconds + 5))
        let config = FetchConfig(mode: .byTime(since: since))
        _ = try? await ingestionCoordinator.ingest(
            service: serviceID,
            adapter: adapter,
            config: config
        )
    }

    // MARK: - Debounce + Triage

    private func scheduleDebounced(
        serviceID: String,
        conversationId: String,
        conversationName: String,
        messages: [Message]
    ) {
        let key = "\(serviceID)|\(conversationId)"
        var accumulated = pendingMessages[key] ?? [:]
        for message in messages {
            accumulated[message.messageId] = message
        }
        pendingMessages[key] = accumulated
        pendingConversationNames[key] = conversationName

        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            await self?.flushDebouncedConversation(
                key: key,
                serviceID: serviceID,
                conversationId: conversationId
            )
        }
    }

    private func flushDebouncedConversation(
        key: String,
        serviceID: String,
        conversationId: String
    ) async {
        guard running else { return }
        let messages = (pendingMessages.removeValue(forKey: key) ?? [:])
            .values
            .sorted { $0.timestamp < $1.timestamp }
        let conversationName = pendingConversationNames.removeValue(forKey: key) ?? conversationId
        debounceTasks[key] = nil
        guard !messages.isEmpty else { return }

        await triageConversation(
            serviceID: serviceID,
            conversationId: conversationId,
            conversationName: conversationName,
            messages: messages
        )
    }

    private func triageConversation(
        serviceID: String,
        conversationId: String,
        conversationName: String,
        messages: [Message]
    ) async {
        let rules = await rulesProvider()
        try? await triageEngine.triage(
            service: serviceID,
            conversationId: conversationId,
            conversationName: conversationName,
            messages: messages,
            rules: rules
        )
    }

    private func receiveNewMessages(_ messages: [Message]) {
        let grouped = Dictionary(grouping: messages) { message in
            "\(message.service)|\(message.conversationId)"
        }
        for group in grouped.values {
            guard let first = group.first, group.contains(where: { !$0.isSent }) else { continue }
            scheduleDebounced(
                serviceID: first.service,
                conversationId: first.conversationId,
                conversationName: first.conversationName ?? first.conversationId,
                messages: group
            )
        }
    }

    private func enqueuePendingUntriagedMessages() async {
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let messages = (try? await db.dbQueue.read { database in
            try Message.fetchAll(
                database,
                sql: """
                    SELECT m.*
                    FROM messages m
                    LEFT JOIN triageEvents t
                      ON t.service = m.service AND t.messageId = m.messageId
                    WHERE m.isSent = 0 AND m.timestamp >= ? AND t.id IS NULL
                    ORDER BY m.timestamp ASC
                    LIMIT 500
                    """,
                arguments: [cutoff]
            )
        }) ?? []
        receiveNewMessages(messages)
    }
}
