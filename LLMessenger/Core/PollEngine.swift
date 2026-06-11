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
    private var pollAllInFlight = false
    var failureCounts: [String: Int] = [:]
    var onPollSucceeded: (() async -> Void)?
    var onPollFailed: ((String, Error) async -> Void)?
    var onHealthWarning: ((String, String) async -> Void)?

    init(database: AppDatabase) {
        self.database = database
    }

    deinit {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
    }

    func register(adapter: MessengerAdapter, config: ServiceConfig) {
        adapters[adapter.serviceID] = adapter
        configs[adapter.serviceID] = config
    }

    // Apply updated config for a running service without restarting the engine.
    func reload(config: ServiceConfig) {
        let serviceID = config.service
        let wasEnabled = configs[serviceID]?.enabled ?? false
        configs[serviceID] = config
        if config.enabled {
            scheduleTimer(serviceID: serviceID, intervalSeconds: config.pollIntervalSeconds)
            // If newly enabled, fire an immediate catch-up poll so messages aren't
            // delayed until the first scheduled timer fires.
            if !wasEnabled {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try await self.pollNow(serviceID: serviceID) }
                    catch { await self.onPollFailed?(serviceID, error) }
                }
            }
        } else {
            timers[serviceID]?.invalidate()
            timers[serviceID] = nil
            nextFireDates.removeValue(forKey: serviceID)
        }
    }

    func start() async {
        // Start all enabled adapters concurrently so a slow/unresponsive adapter
        // (e.g. Telegram timing out) doesn't block iMessage or Signal from starting.
        await withTaskGroup(of: Void.self) { group in
            for (serviceID, config) in configs where config.enabled {
                let intervalSeconds = config.pollIntervalSeconds
                group.addTask { @MainActor [weak self] in
                    guard let self, let adapter = self.adapters[serviceID] else { return }
                    do {
                        try await adapter.start()
                        self.scheduleTimer(serviceID: serviceID, intervalSeconds: intervalSeconds)
                        await self.checkCatchUp(serviceID: serviceID)
                    } catch {
                        self.writeHealth(service: serviceID, status: "error",
                                         error: error.localizedDescription, updateLastCheck: true)
                    }
                }
            }
        }
    }

    // Poll all enabled adapters; fire onPollSucceeded exactly once if any new messages were stored.
    func pollAll() async {
        pollAllInFlight = true
        defer { pollAllInFlight = false }
        let serviceIDs = adapters.keys.filter { configs[$0]?.enabled == true }
        let anyNew = await withTaskGroup(of: Bool.self) { group in
            for serviceID in serviceIDs {
                group.addTask { @MainActor [weak self] in
                    guard let self else { return false }
                    return (try? await self.pollOnce(serviceID: serviceID)) == true
                }
            }
            var result = false
            for await hadNew in group { if hadNew { result = true } }
            return result
        }
        if anyNew { await onPollSucceeded?() }
    }

    // Public: poll one service and fire onPollSucceeded if new messages arrived.
    // Only fires for eager services — on_demand services store messages without auto-briefing.
    // Skips onPollSucceeded if pollAll() is already in flight to avoid duplicate notifications.
    func pollNow(serviceID: String) async throws {
        let isEager = configs[serviceID]?.resolvedPrivacyMode == .eager
        if try await pollOnce(serviceID: serviceID) && isEager && !pollAllInFlight {
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

        // Retry start() for adapters that failed at launch (e.g. FDA granted after app start).
        if adapter.healthStatus != .ok {
            do {
                try await adapter.start()
            } catch {
                let failures = (failureCounts[serviceID] ?? 0) + 1
                failureCounts[serviceID] = failures
                writeHealth(service: serviceID, status: "error", error: error.localizedDescription, updateLastCheck: true)
                throw error
            }
        }

        let fetchConfig = await makeFetchConfig(config: config, serviceID: serviceID)
        let result: AdapterFetchResult
        do {
            result = try await adapter.fetch(config: fetchConfig)
        } catch {
            let failures = (failureCounts[serviceID] ?? 0) + 1
            failureCounts[serviceID] = failures
            NSLog("[PollEngine] %@", "\(serviceID): fetch failed: \(error.localizedDescription)")
            // Fetch failed — write error status; lastCheck advances so the next poll
            // starts from now rather than re-fetching the same (failed) window again.
            writeHealth(service: serviceID, status: "error",
                        error: error.localizedDescription, updateLastCheck: true)
            throw error
        }

        let totalMsgs = result.conversations.reduce(0) { $0 + $1.messages.count }
        NSLog("[PollEngine] %@", "\(serviceID): fetched \(result.conversations.count) conversations, \(totalMsgs) messages")

        do {
            let hadNew = try store(result: result, service: serviceID)
            failureCounts[serviceID] = 0

            let healthResult = await adapter.healthCheck()
            if healthResult.status == .ok {
                writeHealth(service: serviceID, status: "ok", error: nil, updateLastCheck: true)
            } else {
                writeHealth(service: serviceID, status: healthResult.status.rawValue,
                            error: healthResult.reason, updateLastCheck: true)
                if let reason = healthResult.reason {
                    await onHealthWarning?(serviceID, reason)
                }
            }

            return hadNew
        } catch {
            let failures = (failureCounts[serviceID] ?? 0) + 1
            failureCounts[serviceID] = failures
            // Store failed after a successful fetch — do NOT advance lastCheck so the
            // next poll re-fetches the same window and retries the store.
            writeHealth(service: serviceID, status: "error",
                        error: error.localizedDescription, updateLastCheck: false)
            throw error
        }
    }

    private func scheduleTimer(serviceID: String, intervalSeconds: Int) {
        timers[serviceID]?.invalidate()
        let interval = TimeInterval(intervalSeconds > 0 ? intervalSeconds : 900)
        nextFireDates[serviceID] = Date().addingTimeInterval(interval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.nextFireDates[serviceID] = Date().addingTimeInterval(interval)
                do {
                    try await self.pollNow(serviceID: serviceID)
                } catch {
                    await self.onPollFailed?(serviceID, error)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[serviceID] = timer
    }

    var nextFireDate: Date? {
        nextFireDates.values.min()
    }

    var currentServiceHealth: [String: AdapterHealthResult.Status] {
        adapters.mapValues { $0.healthStatus }
    }

    private func readLastCheck(serviceID: String) async -> Date? {
        await Task.detached(priority: .utility) { [database = self.database] in
            try? database.dbQueue.read { db in
                try ServiceHealth.fetchOne(db, key: serviceID)
            }?.lastCheck
        }.value
    }

    private func checkCatchUp(serviceID: String) async {
        guard let config = configs[serviceID] else { return }
        guard let lastCheck = await readLastCheck(serviceID: serviceID) else {
            do { try await pollNow(serviceID: serviceID) }
            catch { await onPollFailed?(serviceID, error) }
            return
        }
        let elapsed = Date().timeIntervalSince(lastCheck)
        let interval = TimeInterval(config.pollIntervalSeconds > 0 ? config.pollIntervalSeconds : 900)
        if elapsed >= interval {
            do { try await pollNow(serviceID: serviceID) }
            catch { await onPollFailed?(serviceID, error) }
        }
    }

    private func makeFetchConfig(config: ServiceConfig, serviceID: String) async -> FetchConfig {
        // On first run (no prior check recorded), fetch the last 48 hours so recent
        // messages are not missed. Subsequent polls use the last-check timestamp.
        let firstRunWindow: TimeInterval = 48 * 3600
        switch config.resolvedFetchMode {
        case .time:
            let since = await readLastCheck(serviceID: serviceID)
                ?? Date().addingTimeInterval(-firstRunWindow)
            return FetchConfig(mode: .byTime(since: since))
        case .count:
            // Always include a time anchor so adapters that respect `since` don't
            // return unlimited history on first run (when lastCheck is nil).
            if let lastCheck = await readLastCheck(serviceID: serviceID) {
                return FetchConfig(mode: .byTime(since: lastCheck))
            }
            let since = Date().addingTimeInterval(-firstRunWindow)
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
                        conversationName: conv.name,
                        messageId: msg.id,
                        sender: msg.sender,
                        text: msg.text,
                        timestamp: msg.timestamp,
                        isSent: msg.isFromMe
                    )
                    try record.insert(db, onConflict: .ignore)
                    if db.changesCount > 0 { hadNew = true }
                }
            }
        }
        return hadNew
    }

    private func writeHealth(service: String, status: String, error: String?, updateLastCheck: Bool) {
        do {
            try database.dbQueue.write { db in
                // Preserve the existing lastCheck when updateLastCheck is false (e.g. store() failed
                // after a successful fetch) so the next poll re-fetches the same time window.
                let lastCheck: Date
                if updateLastCheck {
                    lastCheck = Date()
                } else {
                    lastCheck = (try? ServiceHealth.fetchOne(db, key: service)?.lastCheck) ?? Date()
                }
                let health = ServiceHealth(
                    service: service,
                    status: status,
                    lastCheck: lastCheck,
                    lastError: error,
                    retryAfter: nil
                )
                try health.save(db)
            }
            // Notify any UI observers that the DB-backed health record changed.
            // Settings → Services subscribes to this so cards repaint after every
            // poll (background or manual retry).
            NotificationCenter.default.post(
                name: Notification.Name("com.llmessenger.serviceHealthDidChange"),
                object: nil
            )
        } catch {
            assertionFailure("writeHealth failed: \(error)")
        }
    }
}
