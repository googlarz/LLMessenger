import GRDB
import Foundation

struct ServiceHealth: Codable, FetchableRecord, PersistableRecord {
    var service: String
    var status: String          // "ok" | "warning" | "error"
    var lastCheck: Date?
    var lastError: String?
    var retryAfter: Int?

    static let databaseTableName = "serviceHealth"
}
