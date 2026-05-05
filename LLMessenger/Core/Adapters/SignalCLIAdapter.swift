// LLMessenger/Core/Adapters/SignalCLIAdapter.swift
import Foundation
import GRDB

final class SignalCLIAdapter: MessengerAdapter {
    let serviceID = "signal"
    private(set) var healthStatus: AdapterHealthResult.Status = .warning

    private let accountNumber: String
    private let daemonURL: URL
    private let storeDBPath: String

    init(accountNumber: String, daemonPort: Int = 7583) {
        self.accountNumber = accountNumber
        self.daemonURL = URL(string: "http://localhost:\(daemonPort)/api/v1/rpc")!
        self.storeDBPath = NSHomeDirectory() + "/.local/share/signal-mcp/messages.db"
    }

    // MARK: - MessengerAdapter

    func start() async throws {
        guard FileManager.default.fileExists(atPath: storeDBPath) else {
            throw AdapterError.initFailed("signal-mcp store not found at \(storeDBPath). Ensure the signal-mcp watch daemon is running.")
        }
        healthStatus = .ok
    }

    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        guard FileManager.default.fileExists(atPath: storeDBPath) else {
            return AdapterFetchResult(conversations: [])
        }

        var grdbConfig = Configuration()
        grdbConfig.readonly = true
        let dbQueue = try DatabaseQueue(path: storeDBPath, configuration: grdbConfig)

        let rows: [[String: DatabaseValue]]
        switch config.mode {
        case .byTime(let since):
            let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
            let account = accountNumber
            rows = try await dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT sender, recipient, body, timestamp, group_id
                    FROM messages
                    WHERE timestamp > ? AND body != '' AND sender != ?
                    ORDER BY timestamp ASC
                """, arguments: [sinceMs, account]).map { $0.asDictionary() }
            }
        case .byCount(let limit):
            let account = accountNumber
            rows = try await dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT sender, recipient, body, timestamp, group_id
                    FROM messages
                    WHERE body != '' AND sender != ?
                    ORDER BY timestamp DESC
                    LIMIT ?
                """, arguments: [account, limit]).map { $0.asDictionary() }
            }
        }

        return AdapterFetchResult(conversations: Self.group(rows: rows))
    }

    func send(conversationID: String, text: String) async throws {
        let isGroup = !conversationID.hasPrefix("+")
        var params: [String: Any]
        if isGroup {
            params = ["groupId": conversationID, "message": text]
        } else {
            params = ["recipient": [conversationID], "message": text]
        }
        let body: [String: Any] = ["jsonrpc": "2.0", "method": "send", "id": 1, "params": params]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: daemonURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw AdapterError.sendFailed(message)
        }
    }

    func healthCheck() async -> AdapterHealthResult {
        let storeOK = FileManager.default.fileExists(atPath: storeDBPath)
        healthStatus = storeOK ? .ok : .warning
        return AdapterHealthResult(
            status: healthStatus,
            reason: storeOK ? nil : "signal-mcp store not found",
            retryAfter: nil
        )
    }

    // MARK: - Grouping (static for testability)

    static func group(rows: [[String: DatabaseValue]]) -> [AdapterConversation] {
        var byID: [String: (name: String, type: ConversationType, messages: [AdapterMessage])] = [:]
        var order: [String] = []

        for row in rows {
            guard let body = row["body"]?.storage.value as? String, !body.isEmpty,
                  let sender = row["sender"]?.storage.value as? String,
                  let tsMs = row["timestamp"]?.storage.value as? Int64
            else { continue }

            let date = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000)
            let groupID = row["group_id"]?.storage.value as? String

            let convID: String
            let convName: String
            let convType: ConversationType

            if let gid = groupID {
                convID = gid
                convName = gid
                convType = .group
            } else {
                convID = sender
                convName = sender
                convType = .dm
            }

            let msg = AdapterMessage(
                id: "\(sender)-\(tsMs)",
                sender: sender,
                text: body,
                timestamp: date
            )

            if byID[convID] == nil {
                byID[convID] = (name: convName, type: convType, messages: [])
                order.append(convID)
            }
            byID[convID]!.messages.append(msg)
        }

        return order.compactMap { id in
            guard let entry = byID[id] else { return nil }
            return AdapterConversation(id: id, name: entry.name,
                                       type: entry.type, messages: entry.messages)
        }
    }
}

// MARK: - GRDB Row helper

private extension Row {
    func asDictionary() -> [String: DatabaseValue] {
        Dictionary(uniqueKeysWithValues: columnNames.map { ($0, self[$0] as DatabaseValue) })
    }
}
