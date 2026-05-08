// LLMessenger/Core/Adapters/iMessageAdapter.swift
import Foundation
import GRDB
import Contacts

// Mac absolute time epoch offset from Unix epoch (seconds between 2001-01-01 and 1970-01-01).
private let kMacEpochOffset: TimeInterval = 978_307_200

final class iMessageAdapter: MessengerAdapter {
    let serviceID = "imessage"
    private(set) var healthStatus: AdapterHealthResult.Status = .warning

    private let dbPath: String
    private var dbQueue: DatabaseQueue?
    private var contactNames: [String: String] = [:]  // handle id → display name

    init() {
        self.dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
    }

    // MARK: - MessengerAdapter

    func start() async throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw AdapterError.initFailed("Messages database not found at \(dbPath). Ensure macOS Messages is set up.")
        }
        var cfg = Configuration()
        cfg.readonly = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: cfg)
        contactNames = await loadContactNames()
        healthStatus = .ok
    }

    func stop() {
        dbQueue = nil
        healthStatus = .warning
    }

    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        guard let dbQueue else {
            throw AdapterError.initFailed("Full Disk Access not granted. Open System Settings › Privacy & Security › Full Disk Access and add LLMessenger.")
        }

        // Convert the fetch window to Mac absolute time (nanoseconds).
        let sinceNs: Int64
        switch config.mode {
        case .byTime(let since):
            sinceNs = Int64((since.timeIntervalSince1970 - kMacEpochOffset) * 1_000_000_000)
        case .byCount:
            // byCount is not naturally expressible with the chat.db schema;
            // fall back to 7 days so the query is still bounded.
            sinceNs = Int64((Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970 - kMacEpochOffset) * 1_000_000_000)
        }

        let rows: [(chatGUID: String, displayName: String, style: Int64,
                     handleID: String, text: String, dateNs: Int64, msgRowid: Int64,
                     isFromMe: Bool)]

        rows = try await dbQueue.read { db in
            let sql = """
                SELECT
                    c.guid        AS chat_guid,
                    COALESCE(c.display_name, '') AS display_name,
                    c.style       AS style,
                    COALESCE(h.id, '') AS handle_id,
                    m.text        AS text,
                    m.date        AS date_ns,
                    m.rowid       AS msg_rowid,
                    m.is_from_me  AS is_from_me
                FROM message m
                JOIN chat_message_join cmj ON m.rowid = cmj.message_id
                JOIN chat c               ON cmj.chat_id = c.rowid
                LEFT JOIN handle h        ON m.handle_id = h.rowid
                WHERE m.text IS NOT NULL
                  AND m.text != ''
                  AND m.error  = 0
                  AND m.date   > ?
                ORDER BY m.date ASC
            """
            return try Row.fetchAll(db, sql: sql, arguments: [sinceNs]).compactMap { row in
                guard let text  = row["text"]     as? String, !text.isEmpty,
                      let guid  = row["chat_guid"] as? String,
                      let ns    = row["date_ns"]   as? Int64,
                      let rowid = row["msg_rowid"] as? Int64
                else { return nil }
                let style: Int64 = row["style"]       ?? 45
                let name: String = row["display_name"] ?? ""
                let fromMe: Bool = (row["is_from_me"] as? Int64 ?? 0) == 1
                // For sent DM messages, m.handle_id is NULL (you're the sender).
                // Extract the recipient contact from the chat GUID instead.
                // Format: "iMessage;-;+12345678901" → "+12345678901"
                var handle: String = row["handle_id"] ?? ""
                if handle.isEmpty && fromMe && style != 43 {
                    if let range = guid.range(of: ";-;") {
                        handle = String(guid[range.upperBound...])
                    }
                }
                return (chatGUID: guid, displayName: name, style: style,
                        handleID: handle, text: text, dateNs: ns, msgRowid: rowid,
                        isFromMe: fromMe)
            }
        }

        // For byCount mode, trim to the requested limit.
        let trimmed: [(chatGUID: String, displayName: String, style: Int64,
                        handleID: String, text: String, dateNs: Int64, msgRowid: Int64,
                        isFromMe: Bool)]
        if case .byCount(let limit) = config.mode {
            trimmed = Array(rows.suffix(limit))
        } else {
            trimmed = rows
        }

        return AdapterFetchResult(conversations: Self.group(rows: trimmed, contactNames: contactNames))
    }

    func send(conversationID: String, text: String) async throws {
        // conversationID is either a handle id (DM) or a chat GUID (group).
        let isGroup = conversationID.contains(";+;") || conversationID.hasPrefix("iMessage;+;")

        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if isGroup {
            let escapedGUID = conversationID
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Messages"
                set targetChat to first chat whose id is "\(escapedGUID)"
                send "\(escapedText)" to targetChat
            end tell
            """
        } else {
            let escapedID = conversationID
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Messages"
                set targetService to 1st service whose service type is iMessage
                set targetBuddy to buddy "\(escapedID)" of targetService
                send "\(escapedText)" to targetBuddy
            end tell
            """
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw AdapterError.sendFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func healthCheck() async -> AdapterHealthResult {
        let ok = FileManager.default.fileExists(atPath: dbPath)
        healthStatus = ok ? .ok : .warning
        return AdapterHealthResult(
            status: healthStatus,
            reason: ok ? nil : "Messages database not found",
            retryAfter: nil
        )
    }

    // MARK: - Grouping (static for testability)

    static func group(
        rows: [(chatGUID: String, displayName: String, style: Int64,
                handleID: String, text: String, dateNs: Int64, msgRowid: Int64,
                isFromMe: Bool)],
        contactNames: [String: String] = [:]
    ) -> [AdapterConversation] {
        var byID: [String: (name: String, type: ConversationType, messages: [AdapterMessage])] = [:]
        var order: [String] = []

        for row in rows {
            let isGroup = row.style == 43
            let convID: String
            let convName: String
            let convType: ConversationType

            if isGroup {
                convID   = row.chatGUID
                convName = row.displayName.isEmpty ? row.chatGUID : row.displayName
                convType = .group
            } else {
                convID   = row.handleID
                convName = contactNames[row.handleID] ?? row.handleID
                convType = .dm
            }

            let senderName = row.isFromMe ? "Me" : (contactNames[row.handleID] ?? row.handleID)
            let date = Date(timeIntervalSince1970: TimeInterval(row.dateNs) / 1_000_000_000 + kMacEpochOffset)
            let msg = AdapterMessage(
                id: "imsg-\(row.msgRowid)",
                sender: senderName,
                text: row.text,
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

    // MARK: - Contact name resolution

    private func loadContactNames() async -> [String: String] {
        // CNContactStore requires Contacts permission — fail gracefully if denied.
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .notDetermined else { return [:] }

        if status == .notDetermined {
            let granted = try? await store.requestAccess(for: .contacts)
            guard granted == true else { return [:] }
        }

        var names: [String: String] = [:]
        let keysToFetch = [CNContactGivenNameKey, CNContactFamilyNameKey,
                           CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        try? store.enumerateContacts(with: request) { contact, _ in
            let fullName = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard !fullName.isEmpty else { return }

            // Index by all phone numbers (normalised) and email addresses.
            for phone in contact.phoneNumbers {
                let digits = phone.value.stringValue
                    .components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if !digits.isEmpty { names["+" + digits] = fullName }
                names[phone.value.stringValue] = fullName
            }
            for email in contact.emailAddresses {
                names[email.value as String] = fullName
            }
        }
        return names
    }
}
