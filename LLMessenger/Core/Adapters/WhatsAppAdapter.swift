// LLMessenger/Core/Adapters/WhatsAppAdapter.swift
import Foundation
import GRDB

// Core Data reference date (2001-01-01) offset from the Unix epoch, in seconds.
private let kCoreDataEpochOffset: TimeInterval = 978_307_200

/// Read-only adapter over WhatsApp Desktop's unencrypted Core Data store
/// (`ChatStorage.sqlite`). It can ingest text messages (and, for the user's own
/// media replies, a `[media]` placeholder) but has no way to send:
/// `send` always fails, and `ServiceCapabilities` keeps the rest of the app from
/// queueing sends for this service.
///
/// Message identity is `wa:<chat JID>|<ZSTANZAID>`. WhatsApp's `Z_PK` is not
/// stable across a re-sync and `ZSTANZAID` is only unique per chat, so neither
/// is used alone. The ingestion layer's UNIQUE(service, messageId) with
/// insert-ignore then makes re-ingesting the same message a no-op.
final class WhatsAppAdapter: MessengerAdapter, @unchecked Sendable {
    static let id = "whatsapp"
    static var defaultStorePath: String {
        NSHomeDirectory() + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
    }

    static let notFoundReason =
        "WhatsApp Desktop not found — install it and sign in, and make sure LLMessenger has Full Disk Access."
    static let unreadableReason =
        "Cannot read WhatsApp's database — grant Full Disk Access in System Settings › Privacy & Security."
    static let busyReason = "WhatsApp is busy, will retry."
    static let formatChangedReason =
        "Couldn't read WhatsApp's local data — its format may have changed."

    /// WhatsApp Desktop writes a backlog with old timestamps after wake/launch, so a
    /// read starts this far before the caller's cursor. Re-read messages are dropped
    /// by the ingestion layer's UNIQUE(service, messageId) insert-ignore.
    static let lateSyncLookback: TimeInterval = 24 * 3600
    /// No read goes further back than this, however stale the cursor is (e.g. the
    /// service was disabled for weeks).
    static let maxHistory: TimeInterval = 7 * 24 * 3600
    static let mediaPlaceholder = "[media]"

    /// 0 = text, 7 = text containing a link.
    private static let textTypes: [Int] = [0, 7]
    /// Media types ingested only for the user's own messages, as a `[media]` reply
    /// marker: 1 image, 2 video, 3 voice, 4 contact, 5 location, 8 document, 11 GIF,
    /// 15 sticker. Deliberately an allow-list: system (6, 10) and deleted (14) rows
    /// and anything unknown stay out.
    private static let ownMediaTypes: [Int] = [1, 2, 3, 4, 5, 8, 11, 15]

    let serviceID = WhatsAppAdapter.id
    private(set) var healthStatus: AdapterHealthResult.Status = .warning

    private let storePath: String
    private let now: @Sendable () -> Date
    private let busyTimeout: TimeInterval
    private var started = false

    init(storePath: String = WhatsAppAdapter.defaultStorePath,
         busyTimeout: TimeInterval = 2,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.storePath = storePath
        self.busyTimeout = busyTimeout
        self.now = now
    }

    // MARK: - MessengerAdapter

    func start() async throws {
        guard FileManager.default.fileExists(atPath: storePath) else {
            throw AdapterError.initFailed(Self.notFoundReason)
        }
        do {
            let hasMessages = try await openStore().read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name = 'ZWAMESSAGE'") ?? 0
            }
            guard hasMessages > 0 else {
                throw AdapterError.initFailed(Self.formatChangedReason)
            }
        } catch let error as AdapterError {
            throw error
        } catch {
            switch Self.classify(error) {
            case .busy:
                // Transient: stay startable, report a warning, and let the next poll retry.
                started = true
                healthStatus = .warning
                return
            case .permission:
                throw AdapterError.initFailed(Self.unreadableReason)
            case .other:
                throw AdapterError.initFailed(Self.formatChangedReason)
            }
        }
        started = true
        healthStatus = .ok
    }

    func stop() {
        started = false
        healthStatus = .warning
    }

    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        guard started else { throw AdapterError.initFailed(Self.notFoundReason) }

        let since: Date
        let limit: Int?
        switch config.mode {
        case .byTime(let date):
            since = date
            limit = nil
        case .byCount(let last):
            // Not expressible against this schema without a bound; mirror iMessage.
            since = now().addingTimeInterval(-Self.maxHistory)
            limit = last
        }
        let lowerBound = max(since.addingTimeInterval(-Self.lateSyncLookback),
                             now().addingTimeInterval(-Self.maxHistory))
        let sinceRef = lowerBound.timeIntervalSince1970 - kCoreDataEpochOffset

        let rows: [Row]
        do {
            rows = try await openStore().read { db in
                try Row.fetchAll(db, sql: Self.messageSQL, arguments: [sinceRef])
            }
        } catch {
            switch Self.classify(error) {
            case .busy:
                healthStatus = .warning
                return AdapterFetchResult(conversations: [])
            case .permission:
                throw AdapterError.initFailed(Self.unreadableReason)
            case .other:
                throw AdapterError.initFailed(Self.formatChangedReason)
            }
        }

        var accumulator = ConversationAccumulator()
        var seen = Set<String>()
        var accepted: [(AdapterMessage, jid: String, name: String, type: ConversationType)] = []
        for row in rows {
            guard let jid: String = row["jid"],
                  let stanza: String = row["stanza"],
                  let date: Double = row["date"] else { continue }
            let messageType: Int64 = row["mtype"] ?? 0
            let text: String
            if Self.textTypes.contains(Int(messageType)) {
                guard let body: String = row["text"] else { continue }
                text = body
            } else {
                text = Self.mediaPlaceholder // SQL admits non-text types only for own messages
            }
            let id = Self.messageID(chatJID: jid, stanzaID: stanza)
            // A re-sync can leave the same chat+stanza under two Z_PKs.
            guard seen.insert(id).inserted else { continue }

            let isGroup = jid.hasSuffix("@g.us")
            let fromMe = (row["from_me"] as Int64? ?? 0) == 1
            let partner = Self.clean(row["partner"])
            let chatName = partner
                ?? (isGroup ? "WhatsApp group" : Self.phoneDigits(fromJID: jid).map { "+" + $0 } ?? "WhatsApp contact")

            let sender: String
            if fromMe {
                sender = "Me"
            } else if isGroup {
                sender = Self.clean(row["gm_name"]) ?? Self.clean(row["gm_first"]) ?? Self.clean(row["push_name"])
                    ?? Self.phoneDigits(fromJID: row["gm_jid"] ?? row["from_jid"] ?? "").map { "+" + $0 }
                    ?? "Unknown"
            } else {
                sender = partner ?? Self.clean(row["push_name"])
                    ?? Self.phoneDigits(fromJID: jid).map { "+" + $0 } ?? "Unknown"
            }

            let message = AdapterMessage(
                id: id,
                sender: sender,
                text: text,
                timestamp: Date(timeIntervalSince1970: date + kCoreDataEpochOffset),
                isFromMe: fromMe
            )
            accepted.append((message, jid, chatName, isGroup ? .group : .dm))
        }

        for entry in (limit.map { Array(accepted.suffix($0)) } ?? accepted) {
            accumulator.add(entry.0, conversationID: entry.jid, name: entry.name, type: entry.type)
        }
        return AdapterFetchResult(conversations: accumulator.finish())
    }

    func send(conversationID: String, text: String) async throws {
        throw ReadOnlyServiceError(service: serviceID)
    }

    /// No contact listing: the @ mention picker exists to target a send, which
    /// WhatsApp cannot do.
    func listContacts() async -> [Contact] { [] }

    func healthCheck() async -> AdapterHealthResult {
        guard FileManager.default.fileExists(atPath: storePath) else {
            healthStatus = .warning
            return AdapterHealthResult(status: .warning, reason: Self.notFoundReason, retryAfter: nil)
        }
        do {
            _ = try await openStore().read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
            }
        } catch {
            switch Self.classify(error) {
            case .busy:
                healthStatus = .warning
                return AdapterHealthResult(status: .warning, reason: Self.busyReason, retryAfter: nil)
            case .permission:
                healthStatus = .error
                return AdapterHealthResult(status: .error, reason: Self.unreadableReason, retryAfter: nil)
            case .other:
                healthStatus = .error
                return AdapterHealthResult(status: .error, reason: Self.formatChangedReason, retryAfter: nil)
            }
        }
        healthStatus = started ? .ok : .warning
        return AdapterHealthResult(status: healthStatus,
                                   reason: started ? nil : "WhatsApp adapter not started",
                                   retryAfter: nil)
    }

    // MARK: - Helpers

    static func messageID(chatJID: String, stanzaID: String) -> String {
        "wa:\(chatJID)|\(stanzaID)"
    }

    /// Digits of a 1:1 phone-number JID ("49123@s.whatsapp.net" → "49123"); nil for
    /// groups, LIDs and anything else that is not a dialable number.
    static func phoneDigits(fromJID jid: String) -> String? {
        guard jid.hasSuffix("@s.whatsapp.net") else { return nil }
        let local = jid.prefix(while: { $0 != "@" }).prefix(while: { $0 != ":" })
        guard !local.isEmpty, local.allSatisfy(\.isNumber) else { return nil }
        return String(local)
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private enum StoreFailure { case busy, permission, other }

    /// Busy/locked is transient; open/permission failures are the Full Disk Access
    /// case; everything else (missing table or column, not a database) means the
    /// store's format is not what this adapter expects.
    private static func classify(_ error: Error) -> StoreFailure {
        guard let dbError = error as? DatabaseError else { return .other }
        switch dbError.resultCode {
        case .SQLITE_BUSY, .SQLITE_LOCKED: return .busy
        case .SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_AUTH: return .permission
        default: return .other
        }
    }

    /// Opened per call, strictly read-only: WhatsApp is usually running and writing,
    /// and a short-lived reader never pins its WAL.
    private func openStore() throws -> DatabaseQueue {
        var cfg = Configuration()
        cfg.readonly = true
        cfg.busyMode = .timeout(busyTimeout)
        return try DatabaseQueue(path: openPath(), configuration: cfg)
    }

    /// Opening a WAL database read-only creates `-wal`/`-shm` when they are absent
    /// (WhatsApp not running), which would litter WhatsApp's container. With no `-shm`
    /// nobody else has the store open, so read it as an immutable snapshot instead.
    /// The `file:` URI is honoured by the system SQLite without GRDB passing
    /// SQLITE_OPEN_URI (confirmed by the no-new-files test).
    private func openPath() -> String {
        guard Self.isWALMode(path: storePath),
              !FileManager.default.fileExists(atPath: storePath + "-shm") else { return storePath }
        return URL(fileURLWithPath: storePath).absoluteString + "?immutable=1"
    }

    /// SQLite header bytes 18 and 19 are both 2 for a WAL-mode database.
    private static func isWALMode(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 100), header.count >= 20 else { return false }
        let bytes = Array(header)
        return bytes[18] == 2 && bytes[19] == 2
    }

    private static let messageSQL = """
        SELECT m.ZSTANZAID AS stanza, m.ZTEXT AS text, m.ZMESSAGETYPE AS mtype, m.ZISFROMME AS from_me,
               m.ZMESSAGEDATE AS date, m.ZPUSHNAME AS push_name, m.ZFROMJID AS from_jid,
               c.ZCONTACTJID AS jid, c.ZPARTNERNAME AS partner,
               gm.ZCONTACTNAME AS gm_name, gm.ZFIRSTNAME AS gm_first, gm.ZMEMBERJID AS gm_jid
        FROM ZWAMESSAGE m
        JOIN ZWACHATSESSION c ON m.ZCHATSESSION = c.Z_PK
        LEFT JOIN ZWAGROUPMEMBER gm ON m.ZGROUPMEMBER = gm.Z_PK
        WHERE ((m.ZMESSAGETYPE IN (\(textTypes.map(String.init).joined(separator: ", "))) AND m.ZTEXT IS NOT NULL AND TRIM(m.ZTEXT) != '')
               OR (m.ZISFROMME = 1 AND m.ZMESSAGETYPE IN (\(ownMediaTypes.map(String.init).joined(separator: ", ")))))
          AND m.ZSTANZAID IS NOT NULL AND m.ZSTANZAID != ''
          AND m.ZMESSAGEDATE > ?
          AND COALESCE(c.ZHIDDEN, 0) = 0 AND COALESCE(c.ZREMOVED, 0) = 0
          AND (c.ZCONTACTJID LIKE '%@s.whatsapp.net' OR c.ZCONTACTJID LIKE '%@g.us' OR c.ZCONTACTJID LIKE '%@lid')
        ORDER BY m.ZMESSAGEDATE ASC, m.Z_PK ASC
        """
}
