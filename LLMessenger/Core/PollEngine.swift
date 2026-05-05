import Foundation
import GRDB

@MainActor
final class PollEngine {
    private let database: AppDatabase
    // State accessed only from async contexts — no concurrent access in single-adapter tests
    private var adapters: [String: MessengerAdapter] = [:]
    private var configs: [String: ServiceConfig] = [:]
    private var timers: [String: Timer] = [:]
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

    func pollNow(serviceID: String) async throws {
        guard !inFlight.contains(serviceID) else { return }
        inFlight.insert(serviceID)
        defer { inFlight.remove(serviceID) }

        guard let adapter = adapters[serviceID],
              let config = configs[serviceID] else { return }

        do {
            let fetchConfig = makeFetchConfig(config: config)
            let result = try await adapter.fetch(config: fetchConfig)
            try store(result: result, service: serviceID)
            failureCounts[serviceID] = 0
            writeHealth(service: serviceID, status: "ok", error: nil)
            await onPollSucceeded?()
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
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { try? await self.pollNow(serviceID: serviceID) }
        }
        timers[serviceID] = timer
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

    private func makeFetchConfig(config: ServiceConfig) -> FetchConfig {
        switch config.fetchMode {
        case "time":
            let since = Date().addingTimeInterval(-Double(config.pollIntervalMinutes) * 60)
            return FetchConfig(mode: .byTime(since: since))
        default:
            return FetchConfig(mode: .byCount(last: config.fetchLimit))
        }
    }

    private func store(result: AdapterFetchResult, service: String) throws {
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
                }
            }
        }
    }

    private func writeHealth(service: String, status: String, error: String?) {
        do {
            try database.dbQueue.write { db in
                var health = ServiceHealth(
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
