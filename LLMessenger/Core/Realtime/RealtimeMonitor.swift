// LLMessenger/Core/Realtime/RealtimeMonitor.swift
import Foundation
import GRDB

actor RealtimeMonitor {
    private let adapters: [String: any MessengerAdapter]
    private let db: AppDatabase
    private let notificationManager: NotificationManager
    private let llmClient: any LLMClient
    private let rulesProvider: @Sendable () async -> [PriorityRule]

    private var running = false
    private var pollTasks: [Task<Void, Never>] = []
    private var fsSource: DispatchSourceFileSystemObject?
    private var debounceWorkItems: [String: DispatchWorkItem] = [:]

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
        notificationManager: NotificationManager,
        llmClient: any LLMClient,
        rulesProvider: @escaping @Sendable () async -> [PriorityRule]
    ) {
        self.adapters = adapters
        self.db = db
        self.notificationManager = notificationManager
        self.llmClient = llmClient
        self.rulesProvider = rulesProvider
    }

    func start() async {
        guard !running else { return }
        guard !UserDefaults.standard.bool(forKey: "realtimeFirewallDisabled") else { return }
        running = true

        // iMessage: FSEvents on WAL file
        if let iMessageAdapter = adapters["imessage"],
           FileManager.default.fileExists(atPath: Self.walPath) {
            startFSWatch(adapter: iMessageAdapter)
        } else if adapters["imessage"] != nil {
            // FDA not granted — fall back to 30s poll
            startPollTask(serviceID: "imessage", adapter: adapters["imessage"]!)
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
        debounceWorkItems.values.forEach { $0.cancel() }
        debounceWorkItems.removeAll()
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
        guard let result = try? await adapter.fetch(config: config) else { return }

        for conv in result.conversations {
            scheduleDebounced(
                serviceID: "imessage",
                conversationId: conv.id,
                conversationName: conv.name,
                messages: conv.messages.map { adapterMsgToModel(m: $0, service: "imessage", convId: conv.id, convName: conv.name) }
            )
        }
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
        guard let result = try? await adapter.fetch(config: config) else { return }
        for conv in result.conversations {
            let msgs = conv.messages.map { adapterMsgToModel(m: $0, service: serviceID, convId: conv.id, convName: conv.name) }
            scheduleDebounced(serviceID: serviceID, conversationId: conv.id, conversationName: conv.name, messages: msgs)
        }
    }

    // MARK: - Debounce + Triage

    private func scheduleDebounced(
        serviceID: String,
        conversationId: String,
        conversationName: String,
        messages: [Message]
    ) {
        let key = "\(serviceID)|\(conversationId)"
        debounceWorkItems[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task {
                await self.triageConversation(
                    serviceID: serviceID,
                    conversationId: conversationId,
                    conversationName: conversationName,
                    messages: messages
                )
            }
        }
        debounceWorkItems[key] = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func triageConversation(
        serviceID: String,
        conversationId: String,
        conversationName: String,
        messages: [Message]
    ) async {
        let rules = await rulesProvider()
        let engine = TriageEngine(db: db, llmClient: llmClient, notificationManager: notificationManager)
        try? await engine.triage(
            service: serviceID,
            conversationId: conversationId,
            conversationName: conversationName,
            messages: messages,
            rules: rules
        )
    }

    // MARK: - Helpers

    private func adapterMsgToModel(m: AdapterMessage, service: String, convId: String, convName: String) -> Message {
        Message(
            id: nil,
            briefId: nil,
            service: service,
            conversationId: convId,
            conversationName: convName,
            messageId: m.id,
            sender: m.sender,
            text: m.text,
            timestamp: m.timestamp,
            isSent: m.isFromMe
        )
    }
}
