// LLMessenger/Core/Agent/ActionAuditLog.swift
//
// Append-only audit trail for executed agent actions. Every send/done the agent
// performs — whether user-approved (P1) or delegated (P2) — writes one row to the
// `actionAudit` table so the user can always answer "what did the agent do?".

import GRDB
import Foundation

struct ActionAuditRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var actionKind: String
    var service: String
    var conversationId: String
    var detail: String          // what was sent/done
    var trigger: String         // "approved" | "delegated"
    var createdAt: Date

    static let databaseTableName = "actionAudit"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum ActionAuditLog {
    enum Trigger: String {
        case approved
        case delegated
    }

    static func record(db: AppDatabase,
                       kind: String,
                       service: String,
                       conversationId: String,
                       detail: String,
                       trigger: Trigger,
                       now: Date = Date()) throws {
        try db.dbQueue.write { grdb in
            var row = ActionAuditRecord(
                id: nil,
                actionKind: kind,
                service: service,
                conversationId: conversationId,
                detail: detail,
                trigger: trigger.rawValue,
                createdAt: now
            )
            try row.insert(grdb)
        }
    }
}
