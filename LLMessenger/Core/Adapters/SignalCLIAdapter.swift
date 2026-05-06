// LLMessenger/Core/Adapters/SignalCLIAdapter.swift
import Foundation
import GRDB

final class SignalCLIAdapter: MessengerAdapter {
    let serviceID = "signal"
    private(set) var healthStatus: AdapterHealthResult.Status = .warning

    private let accountNumber: String
    private let daemonURL: URL
    private let storeDBPath: String
    private var dbQueue: DatabaseQueue?

    // Resolved at start(); keyed by UUID (ACI) or phone number.
    private var contactNames: [String: String] = [:]
    // Resolved at start(); keyed by base64 group ID.
    private var groupNames: [String: String] = [:]

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
        var grdbConfig = Configuration()
        grdbConfig.readonly = true
        dbQueue = try DatabaseQueue(path: storeDBPath, configuration: grdbConfig)
        // Load names non-fatally — missing daemon just means raw IDs are shown.
        async let contacts = loadContactNames()
        async let groups   = loadGroupNames()
        (contactNames, groupNames) = await (contacts, groups)
        healthStatus = .ok
    }

    func stop() {
        dbQueue = nil
        healthStatus = .warning
    }

    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        guard let dbQueue else {
            return AdapterFetchResult(conversations: [])
        }

        // Retry name loading if start() ran before the daemon was available.
        if contactNames.isEmpty || groupNames.isEmpty {
            async let contacts = loadContactNames()
            async let groups   = loadGroupNames()
            let (c, g) = await (contacts, groups)
            if !c.isEmpty { contactNames = c }
            if !g.isEmpty { groupNames   = g }
        }

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

        return AdapterFetchResult(conversations: Self.group(
            rows: rows,
            contactNames: contactNames,
            groupNames: groupNames
        ))
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

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AdapterError.sendFailed("HTTP \(http.statusCode)")
        }
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

    /// Resolve a UUID / phone number to a display name. Returns nil when unknown.
    func contactName(for id: String) -> String? { contactNames[id] }
    /// Resolve a base64 group ID to a display name. Returns nil when unknown.
    func groupName(for id: String) -> String? { groupNames[id] }

    // MARK: - Private RPC helpers

    private func rpc(_ method: String, params: [String: Any] = [:]) async throws -> Any? {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": method, "id": 1, "params": params
        ])
        var req = URLRequest(url: daemonURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"]
    }

    private func loadContactNames() async -> [String: String] {
        // allNumbers: true returns phone-book contacts (97) not just Signal-known ones (39).
        guard let contacts = try? await rpc("listContacts", params: ["allNumbers": true])
                as? [[String: Any]] else { return [:] }
        var names: [String: String] = [:]
        for c in contacts {
            let name = extractContactName(from: c)
            guard !name.isEmpty else { continue }
            if let uuid = c["uuid"] as? String, !uuid.isEmpty { names[uuid] = name }
            if let num  = c["number"] as? String, !num.isEmpty  { names[num]  = name }
        }
        // Cross-reference group members: a group member UUID with a known phone number
        // can be resolved even when that UUID isn't in the contacts list directly.
        if let groups = try? await rpc("listGroups") as? [[String: Any]] {
            for group in groups {
                guard let members = group["members"] as? [[String: Any]] else { continue }
                for member in members {
                    guard let uuid  = member["uuid"]   as? String, !uuid.isEmpty,
                          names[uuid] == nil,                    // not already resolved
                          let phone = member["number"] as? String, !phone.isEmpty,
                          let name  = names[phone]               // phone IS resolved
                    else { continue }
                    names[uuid] = name
                }
            }
        }
        return names
    }

    /// Extracts the best available display name from a contact dict.
    private func extractContactName(from c: [String: Any]) -> String {
        // 1. Top-level given+family
        if let g = c["givenName"] as? String, !g.isEmpty {
            let f = c["familyName"] as? String ?? ""
            return f.isEmpty ? g : "\(g) \(f)"
        }
        // 2. Profile given+family (Signal stores display names here)
        if let p = c["profile"] as? [String: Any],
           let g = p["givenName"] as? String, !g.isEmpty {
            let f = p["familyName"] as? String ?? ""
            return f.isEmpty ? g : "\(g) \(f)"
        }
        // 3. Top-level "name" field
        if let n = c["name"] as? String, !n.isEmpty { return n }
        return ""
    }

    private func loadGroupNames() async -> [String: String] {
        guard let groups = try? await rpc("listGroups") as? [[String: Any]] else { return [:] }
        var names: [String: String] = [:]
        for g in groups {
            guard let id = g["id"] as? String, !id.isEmpty else { continue }
            // "name" is the standard field; fall back to "title" used by some versions.
            let name = (g["name"] as? String ?? "").isEmpty
                ? (g["title"] as? String ?? "")
                : (g["name"] as? String ?? "")
            if !name.isEmpty { names[id] = name }
        }
        return names
    }

    // MARK: - Grouping (static for testability)

    /// Groups raw signal-mcp rows into adapter conversations.
    /// `contactNames` maps UUID (ACI) or phone number → display name.
    /// `groupNames`   maps base64 group ID → group title.
    /// Both default to empty so callers in tests need no changes.
    static func group(
        rows: [[String: DatabaseValue]],
        contactNames: [String: String] = [:],
        groupNames: [String: String] = [:]
    ) -> [AdapterConversation] {
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

            // signal-mcp stores group_id as "" (empty string) for DMs, not NULL
            if let gid = groupID, !gid.isEmpty {
                convID = gid
                convName = groupNames[gid] ?? gid
                convType = .group
            } else {
                convID = sender
                convName = contactNames[sender] ?? sender
                convType = .dm
            }

            // Fall back to "Unknown" for unresolvable UUIDs (long hex strings, not names).
            let senderName = contactNames[sender] ?? (sender.count > 20 ? "Unknown" : sender)
            let msg = AdapterMessage(
                id: "\(sender)-\(tsMs)",
                sender: senderName,
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
