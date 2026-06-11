import GRDB
import Foundation

enum BriefStatus: String, Codable {
    case ready
    case open
    case idle
}

struct Brief: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var createdAt: Date
    var status: String          // stored as raw string for DB compat; use BriefStatus for logic
    var services: String        // JSON-encoded [String]
    var failedServices: String?  // JSON-encoded [String]
    var openingSummary: String?
    var notificationText: String
    var episodicSummary: String?
    var pinned: Bool
    /// Start of the fetch window. nil for hourly auto-poll briefs; set for on-demand summarizeLast() briefs.
    var windowStart: Date?
    var archivedAt: Date?
    var snoozedUntil: Date?

    static let databaseTableName = "briefs"

    var briefStatus: BriefStatus { BriefStatus(rawValue: status) ?? .idle }

    init(id: Int64? = nil,
         createdAt: Date,
         status: String,
         services: String,
         failedServices: String? = nil,
         openingSummary: String? = nil,
         notificationText: String,
         episodicSummary: String? = nil,
         pinned: Bool = false,
         windowStart: Date? = nil,
         archivedAt: Date? = nil,
         snoozedUntil: Date? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.services = services
        self.failedServices = failedServices
        self.openingSummary = openingSummary
        self.notificationText = notificationText
        self.episodicSummary = episodicSummary
        self.pinned = pinned
        self.windowStart = windowStart
        self.archivedAt = archivedAt
        self.snoozedUntil = snoozedUntil
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
