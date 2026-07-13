import Foundation
import GRDB

enum BriefJobKind: String, Codable {
    case automatic
    case historical
}

enum BriefJobStatus: String, Codable {
    case queued
    case running
    case partial
    case succeeded
    case failed
    case deadLetter = "dead_letter"
}

enum BriefJobMessageStatus: String, Codable {
    case pending
    case succeeded
    case skipped
}

struct BriefJob: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var kind: String
    var status: String
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var nextAttemptAt: Date?
    var attemptCount: Int
    var lastError: String?

    static let databaseTableName = "briefJobs"

    var jobKind: BriefJobKind { BriefJobKind(rawValue: kind) ?? .automatic }
    var jobStatus: BriefJobStatus { BriefJobStatus(rawValue: status) ?? .failed }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct BriefJobMessage: Codable, FetchableRecord, PersistableRecord {
    var jobId: Int64
    var messageRowId: Int64
    var status: String
    var completedAt: Date?
    var briefId: Int64?

    static let databaseTableName = "briefJobMessages"

    var messageStatus: BriefJobMessageStatus {
        BriefJobMessageStatus(rawValue: status) ?? .pending
    }
}

struct BriefJobSnapshot {
    var job: BriefJob
    var messages: [Message]
}
