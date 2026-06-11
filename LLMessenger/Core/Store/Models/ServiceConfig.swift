import GRDB

enum PrivacyMode: String, Codable {
    case eager
    case onDemand = "on_demand"
}

enum FetchMode: String, Codable {
    case time
    case count
}

struct ServiceConfig: Codable, FetchableRecord, PersistableRecord {
    var service: String
    var enabled: Bool
    var pollIntervalMinutes: Int
    var fetchMode: String       // stored as raw string; use FetchMode enum for logic
    var fetchLimit: Int
    var privacyMode: String     // stored as raw string; use PrivacyMode enum for logic
    var pollIntervalSeconds: Int

    static let databaseTableName = "serviceConfig"

    var resolvedPrivacyMode: PrivacyMode { PrivacyMode(rawValue: privacyMode) ?? .onDemand }
    var resolvedFetchMode: FetchMode { FetchMode(rawValue: fetchMode) ?? .count }

    init(service: String, enabled: Bool, pollIntervalMinutes: Int,
         fetchMode: String, fetchLimit: Int, privacyMode: String,
         pollIntervalSeconds: Int = 900) {
        self.service = service
        self.enabled = enabled
        self.pollIntervalMinutes = pollIntervalMinutes
        self.fetchMode = fetchMode
        self.fetchLimit = fetchLimit
        self.privacyMode = privacyMode
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    static func `default`(for service: String) -> ServiceConfig {
        return ServiceConfig(service: service, enabled: true,
                             pollIntervalMinutes: 30, fetchMode: FetchMode.time.rawValue,
                             fetchLimit: 50, privacyMode: PrivacyMode.onDemand.rawValue)
    }
}
