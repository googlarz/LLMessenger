import Foundation
import GRDB

@MainActor
final class PollEngine {
    private let database: AppDatabase
    private var adapters: [String: MessengerAdapter] = [:]
    private var configs: [String: ServiceConfig] = [:]
    private var timers: [String: Timer] = [:]
    private var nextFireDates: [String: Date] = [:]
    private var inFlight: Set<String> = []
    var failureCounts: [String: Int] = [:]
    var onPollSucceeded: (() async -> Void)?

    init(database: AppDatabase) {
        self.database = database
    }

    func register(adapter: MessengerAdapter, config: ServiceConfig) {
        adapters[adapter.serviceID] = adapter
        configs[adapter.serviceID] = config
    }

    // Apply updated config for a running service without restarting the engine.
    func reload(config: ServiceConfig) {
        let serviceID = config.service
        configs[serviceID] = config
        if config.enabled {
            scheduleTimer(serviceID: serviceID, intervalMinutes: config.pollIntervalMinutes)
        } else {
            timers[serviceID]?.invalidate()
            timers[serviceID] = nil
            nextFireDates.removeValue(forKey: serviceID)
        }
    }

    func start() async {
        for (serviceID, config) in configs where config.enabled {
            guard let adapter = adapters[serviceID] else { continue }
            do {
                try await adapter.start()
                scheduleTimer(serviceID: serviceID, intervalMinutes: config.pollIntervalMinutes)
                await checkCatchUp(serviceID: serviceID)
            } catch {
                writeHealth(service: serviceID, status: "error",
                            error: error.localizedDescription)
            }
        }
    }

    // Poll all adapters; fire onPollSucceeded exactly once if any new messages were stored.
    func pollAll() async {
        var anyNew = false
        for serviceID in adapters.keys {
            if (try? await pollOnce(serviceID: serviceID)) == true {
                anyNew = true
            }
        }
        if anyNew {
            await onPollSucceeded?()
        }
    }

    // Public: poll one service and fire onPollSucceeded if new messages arrived.
    // Only fires for eager services — on_demand services store messages without auto-briefing.
    func pollNow(serviceID: String) async throws {
        let isEager = configs[serviceID]?.resolvedPrivacyMode == .eager
        if try await pollOnce(serviceID: serviceID) && isEager {
            await onPollSucceeded?()
        }
    }

    // MARK: - Private

    // Core poll: fetch, store, update health. Returns true iff new messages were inserted.
    @discardableResult
    private func pollOnce(serviceID: String) async throws -> Bool {
        guard !inFlight.contains(serviceID) else { return false }
        inFlight.insert(serviceID)
        defer { inFlight.remove(serviceID) }

        guard let adapter = adapters[serviceID],
              let config = configs[serviceID] else { return false }

        do {
            let fetchConfig = makeFetchConfig(config: config, serviceID: serviceID)
            let result = try await adapter.fetch(config: fetchConfig)
            let hadNew = try store(result: result, service: serviceID)
            failureCounts[serviceID] = 0
            writeHealth(service: serviceID, status: "ok", error: nil)
            return hadNew
        } catch {
            let failures = (failureCounts[serviceID] ?? 0) + 1
            failureCounts[serviceID] = failures
            writeHealth(service: serviceID, status: "error",
                        error: error.localizedDescription)
            throw error
        }
    }

    private func scheduleTimer(serviceID: String, intervalMinutes: Int) {
        timers[serviceID]?.invalidate()
        let interval = TimeInterval(intervalMinutes * 60)
        nextFireDates[serviceID] = Date().addingTimeInterval(interval)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.nextFireDates[serviceID] = Date().addingTimeInterval(interval)
                try? await self.pollNow(serviceID: serviceID)
            }
        }
        timers[serviceID] = timer
    }

    var nextFireDate: Date? {
        nextFireDates.values.min()
    }

    var currentServiceHealth: [String: AdapterHealthResult.Status] {
        adapters.mapValues { $0.healthStatus }
    }

    private func readLastCheck(serviceID: String) -> Date? {
        try? database.dbQueue.read { db in
            try ServiceHealth.fetchOne(db, key: serviceID)
        }?.lastCheck
    }

    private func checkCatchUp(serviceID: String) async {
        guard let config = configs[serviceID] else { return }
        guard let lastCheck = readLastCheck(serviceID: serviceID) else {
            try? await pollNow(serviceID: serviceID)
            return
        }
        let elapsed = Date().timeIntervalSince(lastCheck)
        let interval = TimeInterval(config.pollIntervalMinutes * 60)
        if elapsed >= interval {
            try? await pollNow(serviceID: serviceID)
        }
    }

    private func makeFetchConfig(config: ServiceConfig, serviceID: String) -> FetchConfig {
        switch config.resolvedFetchMode {
        case .time:
            let since = readLastCheck(serviceID: serviceID)
                ?? Date().addingTimeInterval(-Double(config.pollIntervalMinutes) * 60)
            return FetchConfig(mode: .byTime(since: since))
        case .count:
            // Always include a time anchor so adapters that respect `since` don't
            // return unlimited history on first run (when lastCheck is nil).
            if let lastCheck = readLastCheck(serviceID: serviceID) {
                return FetchConfig(mode: .byTime(since: lastCheck))
            }
            // No prior check: fetch only the last poll-interval window.
            let since = Date().addingTimeInterval(-Double(config.pollIntervalMinutes) * 60)
            return FetchConfig(mode: .byTime(since: since))
        }
    }

    // Returns true if at least one new message was inserted (not a duplicate).
    private func store(result: AdapterFetchResult, service: String) throws -> Bool {
        var hadNew = false
        try database.dbQueue.write { db in
            for conv in result.conversations {
                for msg in conv.messages {
                    var record = Message(
                        briefId: nil,
                        service: service,
                        conversationId: conv.id,
                        messageId: msg.id,
                        sender: msg.sender,
                        text: msg.text,
                        timestamp: msg.timestamp,
                        isSent: false
                    )
                    try record.insert(db, onConflict: .ignore)
                    if db.changesCount > 0 { hadNew = true }
                }
            }
        }
        return hadNew
    }

    private func writeHealth(service: String, status: String, error: String?) {
        do {
            try database.dbQueue.write { db in
                let health = ServiceHealth(
                    service: service,
                    status: status,
                    lastCheck: Date(),
                    lastError: error,
                    retryAfter: nil
                )
                try health.save(db)
            }
        } catch {
            assertionFailure("writeHealth failed: \(error)")
        }
    }
}
