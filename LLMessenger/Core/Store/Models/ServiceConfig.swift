import GRDB

struct ServiceConfig: Codable, FetchableRecord, PersistableRecord {
    var service: String
    var enabled: Bool
    var pollIntervalMinutes: Int
    var fetchMode: String       // "time" | "count"
    var fetchLimit: Int
    var privacyMode: String     // "eager" | "on_demand"

    static let databaseTableName = "serviceConfig"

    static func `default`(for service: String) -> ServiceConfig {
        ServiceConfig(service: service, enabled: true,
                      pollIntervalMinutes: 30, fetchMode: "count",
                      fetchLimit: 50, privacyMode: "on_demand")
    }
}
