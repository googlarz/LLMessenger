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
        self.daemonURL = URL(string: "http://127.0.0.1:\(daemonPort)/api/v1/rpc")!
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
        // Load names: try signal-cli daemon RPC first, then fill gaps from signal-mcp's
        // conversations table (populated by desktop sync). This way names resolve even
        // when the daemon isn't running.
        async let contacts = loadContactNames()
        async let groups   = loadGroupNames()
        (contactNames, groupNames) = await (contacts, groups)
        let storeNames = await loadNamesFromStore()
        for (key, name) in storeNames.contacts where contactNames[key] == nil {
            contactNames[key] = name
        }
        for (key, name) in storeNames.groups where groupNames[key] == nil {
            groupNames[key] = name
        }
        if contactNames.isEmpty && groupNames.isEmpty && !isWatchDaemonRunning() {
            healthStatus = .warning
        } else {
            healthStatus = .ok
        }
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
            let storeNames = await loadNamesFromStore()
            for (key, name) in storeNames.contacts where contactNames[key] == nil {
                contactNames[key] = name
            }
            for (key, name) in storeNames.groups where groupNames[key] == nil {
                groupNames[key] = name
            }
        }

        // Snapshot before any concurrent work so reads inside closures
        // don't race with mutations from a concurrent fetch() call.
        let snapshotContactNames = contactNames
        let snapshotGroupNames   = groupNames

        let rows: [[String: DatabaseValue]]
        switch config.mode {
        case .byTime(let since):
            let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
            rows = try await dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT sender, recipient, body, timestamp, group_id
                    FROM messages
                    WHERE timestamp > ? AND body != ''
                    ORDER BY timestamp ASC
                """, arguments: [sinceMs]).map { $0.asDictionary() }
            }
        case .byCount(let limit):
            rows = try await dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT sender, recipient, body, timestamp, group_id
                    FROM messages
                    WHERE body != ''
                    ORDER BY timestamp DESC
                    LIMIT ?
                """, arguments: [limit]).map { $0.asDictionary() }
            }
        }

        return AdapterFetchResult(conversations: Self.group(
            rows: rows,
            contactNames: snapshotContactNames,
            groupNames: snapshotGroupNames,
            accountNumber: accountNumber
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

    func listContacts() async -> [Contact] {
        var contacts: [Contact] = []
        // Group DMs by display name so a single person with multiple handles (UUID + phone)
        // appears once.
        var byName: [String: [String]] = [:]
        for (handle, name) in contactNames where handle != accountNumber {
            byName[name, default: []].append(handle)
        }
        for (name, handles) in byName {
            // Prefer the phone-number handle as the conversation ID; signal-cli uses these
            // for send. UUIDs work too but are less stable across syncs.
            let primary = handles.first { $0.hasPrefix("+") } ?? handles.first ?? ""
            guard !primary.isEmpty else { continue }
            contacts.append(Contact(
                id: "signal:dm:\(primary)",
                displayName: name,
                handles: [ServiceHandle(service: serviceID, conversationId: primary, isGroup: false)]
            ))
        }
        for (groupID, groupName) in groupNames {
            contacts.append(Contact(
                id: "signal:group:\(groupID)",
                displayName: groupName,
                handles: [ServiceHandle(service: serviceID, conversationId: groupID, isGroup: true)]
            ))
        }
        return contacts
    }

    func healthCheck() async -> AdapterHealthResult {
        guard FileManager.default.fileExists(atPath: storeDBPath) else {
            healthStatus = .warning
            return AdapterHealthResult(status: .warning, reason: "signal-mcp store not found", retryAfter: nil)
        }

        // Daemon liveness is the source of truth. If launchd reports the watch
        // service as running, the daemon is fine — even if the user just hasn't
        // received any Signal messages for hours. Don't mistake "quiet" for "stuck".
        let daemonRunning = isWatchDaemonRunning()
        if daemonRunning {
            healthStatus = .ok
            return AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil)
        }

        // Daemon is NOT running. Try the existing auto-recovery (lock conflict
        // detection + kickstart) before giving up.
        let hasLockConflict = detectReceiveLockConflict()
        if hasLockConflict {
            NSLog("[SignalCLIAdapter] Receive lock conflict detected — attempting auto-recovery")
            let recovered = await restartWatchDaemon()
            if recovered {
                healthStatus = .warning
                return AdapterHealthResult(
                    status: .warning,
                    reason: "Signal watch daemon was stuck — restarted; next poll will go green",
                    retryAfter: nil
                )
            }
        }

        let daemonDiag = readWatchDaemonError()
        let stale = await checkDataFreshness()
        var reason = "Signal watch daemon isn't running. Start it (`signal-mcp watch`) or click Retry now."
        if let diag = daemonDiag { reason += "\n" + diag }
        if let last = stale.newestMessageDate {
            let hours = Int(Date().timeIntervalSince(last) / 3600)
            reason += "\nLast message synced \(hours)h ago."
        }
        healthStatus = .warning
        return AdapterHealthResult(status: .warning, reason: reason, retryAfter: nil)
    }

    /// True when launchd reports gui/<uid>/com.signal-mcp.watch as running.
    /// This is the actual signal we want — distinguishes "daemon alive, just quiet"
    /// from "daemon dead". `launchctl print` is the canonical check.
    private func isWatchDaemonRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/com.signal-mcp.watch"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return false }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return false }
            // launchctl print includes "state = running" when the service is up.
            return text.contains("state = running")
        } catch {
            return false
        }
    }

    private static let stalenessThreshold: TimeInterval = 2 * 3600

    private struct FreshnessResult {
        let isStale: Bool
        let reason: String
        let newestMessageDate: Date?
    }

    private func checkDataFreshness() async -> FreshnessResult {
        guard let dbQueue else {
            return FreshnessResult(isStale: true, reason: "Signal DB not open", newestMessageDate: nil)
        }
        let newestMs: Int64? = try? await dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(timestamp) FROM messages")
        }
        guard let ms = newestMs, ms > 0 else {
            return FreshnessResult(isStale: true, reason: "No messages in signal-mcp store", newestMessageDate: nil)
        }
        let newestDate = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let age = Date().timeIntervalSince(newestDate)
        if age > Self.stalenessThreshold {
            let hours = Int(age / 3600)
            let reason = "Signal watch daemon may be stuck — newest message is \(hours)h old"
            return FreshnessResult(isStale: true, reason: reason, newestMessageDate: newestDate)
        }
        return FreshnessResult(isStale: false, reason: "", newestMessageDate: newestDate)
    }

    private static let watchErrPath = NSHomeDirectory() + "/.local/share/signal-mcp/watch.err"

    private func detectReceiveLockConflict() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.watchErrPath)),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("Receive command cannot be used if messages are already being received")
    }

    private func readWatchDaemonError() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.watchErrPath)),
              !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let tail = lines.suffix(3).joined(separator: "\n")
        return tail.isEmpty ? nil : "Watch daemon log: \(tail)"
    }

    func restartWatchDaemon() async -> Bool {
        // Kill any signal-cli process (daemon, receive, or otherwise) that may hold
        // the receive lock and prevent the watch daemon from working.
        for pattern in ["signal-cli.*daemon", "signal-cli.*receive", "org.asamk.signal.Main"] {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", pattern]
            try? kill.run()
            kill.waitUntilExit()
        }

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Clear the error log so stale "receive lock" errors don't persist.
        try? "".write(toFile: Self.watchErrPath, atomically: true, encoding: .utf8)

        let kickstart = Process()
        kickstart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kickstart.arguments = ["kickstart", "-k", "gui/\(getuid())/com.signal-mcp.watch"]
        do {
            try kickstart.run()
            kickstart.waitUntilExit()
            return kickstart.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Resolve a UUID / phone number to a display name. Returns nil when unknown.
    func contactName(for id: String) -> String? { contactNames[id] }
    /// Resolve a base64 group ID to a display name. Returns nil when unknown.
    func groupName(for id: String) -> String? { groupNames[id] }

    /// Reads conversation names from signal-mcp's `conversations` table (populated by desktop sync).
    private func loadNamesFromStore() async -> (contacts: [String: String], groups: [String: String]) {
        guard let dbQueue else { return ([:], [:]) }
        let rows = try? await dbQueue.read { db -> [(id: String, name: String, type: String)] in
            try Row.fetchAll(db, sql: "SELECT id, name, type FROM conversations").compactMap { row in
                guard let id = row["id"] as? String,
                      let name = row["name"] as? String,
                      let type = row["type"] as? String else { return nil }
                return (id: id, name: name, type: type)
            }
        }
        var contacts: [String: String] = [:]
        var groups: [String: String] = [:]
        for row in rows ?? [] {
            if row.type == "group" {
                groups[row.id] = row.name
            } else {
                contacts[row.id] = row.name
            }
        }
        return (contacts, groups)
    }

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
        let contactsResult: [[String: Any]]?
        do {
            contactsResult = try await rpc("listContacts", params: ["allNumbers": true]) as? [[String: Any]]
        } catch {
            NSLog("[SignalCLIAdapter] loadContactNames failed: %@", error.localizedDescription)
            if !isWatchDaemonRunning() { healthStatus = .warning }
            return [:]
        }
        guard let contacts = contactsResult else { return [:] }
        var names: [String: String] = [:]
        for c in contacts {
            let name = extractContactName(from: c)
            guard !name.isEmpty else { continue }
            if let uuid = c["uuid"] as? String, !uuid.isEmpty { names[uuid] = name }
            if let num  = c["number"] as? String, !num.isEmpty  { names[num]  = name }
        }
        // Cross-reference group members: a group member UUID with a known phone number
        // can be resolved even when that UUID isn't in the contacts list directly.
        let groupsForCrossRef: [[String: Any]]?
        do {
            groupsForCrossRef = try await rpc("listGroups") as? [[String: Any]]
        } catch {
            NSLog("[SignalCLIAdapter] loadContactNames/listGroups failed: %@", error.localizedDescription)
            groupsForCrossRef = nil
        }
        if let groups = groupsForCrossRef {
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
        // Fill remaining gaps from signal-cli's own profile store (has names for contacts
        // who never accepted a message request or have no phone number in group membership).
        let cliNames = await loadNamesFromSignalCliDB()
        for (key, name) in cliNames where names[key] == nil {
            names[key] = name
        }
        return names
    }

    /// Reads ACI → display name from signal-cli's local recipient store.
    /// This covers group members whose phone number is not exposed via the RPC API.
    private func loadNamesFromSignalCliDB() async -> [String: String] {
        guard let dbPath = signalCliAccountDBPath,
              FileManager.default.fileExists(atPath: dbPath) else { return [:] }
        var config = Configuration()
        config.readonly = true
        guard let db = try? DatabaseQueue(path: dbPath, configuration: config) else { return [:] }
        let names = try? await db.read { db -> [String: String] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT aci, number, given_name, family_name, profile_given_name, profile_family_name
                FROM recipient
                WHERE aci IS NOT NULL
            """)
            var result: [String: String] = [:]
            for row in rows {
                guard let aci = row["aci"] as? String, !aci.isEmpty else { continue }
                let given  = (row["given_name"]  as? String ?? "").isEmpty
                    ? (row["profile_given_name"]  as? String ?? "")
                    : (row["given_name"]  as? String ?? "")
                let family = (row["family_name"] as? String ?? "").isEmpty
                    ? (row["profile_family_name"] as? String ?? "")
                    : (row["family_name"] as? String ?? "")
                let name = family.isEmpty ? given : "\(given) \(family)"
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                result[aci] = trimmed
                if let phone = row["number"] as? String, !phone.isEmpty {
                    result[phone] = trimmed
                }
            }
            return result
        }
        return names ?? [:]
    }

    /// Path to signal-cli's account database for this account number.
    private var signalCliAccountDBPath: String? {
        let jsonPath = NSHomeDirectory() + "/.local/share/signal-cli/data/accounts.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["accounts"] as? [[String: Any]] else { return nil }
        for account in accounts {
            guard let number = account["number"] as? String, number == accountNumber,
                  let path = account["path"] as? String else { continue }
            return NSHomeDirectory() + "/.local/share/signal-cli/data/\(path).d/account.db"
        }
        return nil
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
        let groupsResult: [[String: Any]]?
        do {
            groupsResult = try await rpc("listGroups") as? [[String: Any]]
        } catch {
            NSLog("[SignalCLIAdapter] loadGroupNames failed: %@", error.localizedDescription)
            if !isWatchDaemonRunning() { healthStatus = .warning }
            return [:]
        }
        guard let groups = groupsResult else { return [:] }
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
        groupNames: [String: String] = [:],
        accountNumber: String? = nil
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
            let recipient = row["recipient"]?.storage.value as? String
            let isFromMe = accountNumber != nil && sender == accountNumber

            let convID: String
            let convName: String
            let convType: ConversationType

            // signal-mcp stores group_id as "" (empty string) for DMs, not NULL
            if let gid = groupID, !gid.isEmpty {
                convID = gid
                convName = groupNames[gid] ?? gid
                convType = .group
            } else if isFromMe, let recip = recipient, !recip.isEmpty {
                convID = recip
                convName = contactNames[recip] ?? (recip.count > 20 ? "Unknown" : recip)
                convType = .dm
            } else {
                convID = sender
                convName = contactNames[sender] ?? sender
                convType = .dm
            }

            let senderName = isFromMe ? "Me" : (contactNames[sender] ?? (sender.count > 20 ? "Unknown" : sender))
            let msg = AdapterMessage(
                id: "\(sender)-\(tsMs)",
                sender: senderName,
                text: body,
                timestamp: date,
                isFromMe: isFromMe
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
