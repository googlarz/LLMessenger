import Foundation
import GRDB

struct MessageIngestionBatch {
    let conversationCount: Int
    let messageCount: Int
    let newMessages: [Message]
    let pendingMessageWatermark: Int64?
}

enum MessageIngestionError: LocalizedError {
    case fetch(service: String, underlying: Error)
    case persistence(service: String, underlying: Error)

    var isPersistenceFailure: Bool {
        if case .persistence = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .fetch(let service, let underlying):
            return "Could not fetch \(service): \(underlying.localizedDescription)"
        case .persistence(let service, let underlying):
            return "Could not store \(service) messages: \(underlying.localizedDescription)"
        }
    }
}

/// The single fetch-and-store boundary shared by scheduled briefs and realtime triage.
/// It serializes adapter access per service and publishes each inserted message once.
actor MessageIngestionCoordinator {
    typealias NewMessagesHandler = @Sendable ([Message]) async -> Void

    private struct ActiveIngestion {
        let id: UUID
        let config: FetchConfig
        let task: Task<MessageIngestionBatch, Error>
    }

    private let database: AppDatabase
    private var activeByService: [String: ActiveIngestion] = [:]
    private var newMessagesHandler: NewMessagesHandler?

    init(database: AppDatabase) {
        self.database = database
    }

    func setNewMessagesHandler(_ handler: NewMessagesHandler?) {
        newMessagesHandler = handler
    }

    func ingest(
        service: String,
        adapter: any MessengerAdapter,
        config: FetchConfig
    ) async throws -> MessageIngestionBatch {
        while let active = activeByService[service] {
            let batch = try await active.task.value
            await finishIfCurrent(active, service: service, batch: batch)
            if Self.covers(active.config, requested: config) {
                return batch
            }
        }

        let id = UUID()
        let database = self.database
        let task = Task {
            let result: AdapterFetchResult
            do {
                result = try await adapter.fetch(config: config)
            } catch {
                throw MessageIngestionError.fetch(service: service, underlying: error)
            }

            do {
                return try Self.persist(result, service: service, database: database)
            } catch {
                throw MessageIngestionError.persistence(service: service, underlying: error)
            }
        }
        let active = ActiveIngestion(id: id, config: config, task: task)
        activeByService[service] = active

        do {
            let batch = try await task.value
            await finishIfCurrent(active, service: service, batch: batch)
            return batch
        } catch {
            if activeByService[service]?.id == id {
                activeByService[service] = nil
            }
            throw error
        }
    }

    private func finishIfCurrent(
        _ active: ActiveIngestion,
        service: String,
        batch: MessageIngestionBatch
    ) async {
        guard activeByService[service]?.id == active.id else { return }
        activeByService[service] = nil
        guard !batch.newMessages.isEmpty, let handler = newMessagesHandler else { return }
        await handler(batch.newMessages)
    }

    private static func covers(_ completed: FetchConfig, requested: FetchConfig) -> Bool {
        switch (completed.mode, requested.mode) {
        case (.byTime(let completedSince), .byTime(let requestedSince)):
            return completedSince <= requestedSince
        case (.byCount(let completedCount), .byCount(let requestedCount)):
            return completedCount >= requestedCount
        default:
            return false
        }
    }

    private static func persist(
        _ result: AdapterFetchResult,
        service: String,
        database: AppDatabase
    ) throws -> MessageIngestionBatch {
        var newMessages: [Message] = []
        let messageCount = result.conversations.reduce(0) { $0 + $1.messages.count }

        let pendingWatermark = try database.dbQueue.write { db -> Int64? in
            for conversation in result.conversations {
                for message in conversation.messages {
                    var record = Message(
                        briefId: nil,
                        service: service,
                        conversationId: conversation.id,
                        conversationName: conversation.name,
                        messageId: message.id,
                        sender: message.sender,
                        text: message.text,
                        timestamp: message.timestamp,
                        isSent: message.isFromMe
                    )
                    try record.insert(db, onConflict: .ignore)
                    if db.changesCount > 0 {
                        newMessages.append(record)
                    }
                }
            }

            return try Int64.fetchOne(
                db,
                sql: "SELECT MAX(id) FROM messages WHERE service = ? AND briefId IS NULL",
                arguments: [service]
            )
        }

        return MessageIngestionBatch(
            conversationCount: result.conversations.count,
            messageCount: messageCount,
            newMessages: newMessages,
            pendingMessageWatermark: pendingWatermark
        )
    }
}
