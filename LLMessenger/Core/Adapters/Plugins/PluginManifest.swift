import Foundation

struct PluginManifest: Codable {
    let name: String
    let binary: String
    let protocolVersion: Int
    let services: [String]
}
