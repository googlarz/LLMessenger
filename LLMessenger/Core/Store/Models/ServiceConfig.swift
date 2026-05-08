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

    static let databaseTableName = "serviceConfig"

    var resolvedPrivacyMode: PrivacyMode { PrivacyMode(rawValue: privacyMode) ?? .onDemand }
    var resolvedFetchMode: FetchMode { FetchMode(rawValue: fetchMode) ?? .count }

    static func `default`(for service: String) -> ServiceConfig {
        return ServiceConfig(service: service, enabled: true,
                             pollIntervalMinutes: 30, fetchMode: FetchMode.time.rawValue,
                             fetchLimit: 50, privacyMode: PrivacyMode.onDemand.rawValue)
    }
}
