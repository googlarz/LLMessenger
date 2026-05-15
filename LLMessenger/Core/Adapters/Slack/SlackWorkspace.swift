import Foundation

struct SlackWorkspace: Codable, Hashable, Identifiable {
    let teamId: String
    let teamName: String
    let token: String          // xoxp-…
    let userId: String         // the authed user inside this team
    let userName: String       // the authed user's display name

    var id: String { teamId }
}

/// Single Keychain blob storing all the user's Slack workspace tokens. Keychain treats
/// the value as opaque, but we serialize as JSON so adding or removing a workspace
/// only touches one row.
enum SlackWorkspaceStore {
    private static let account = "slack_workspaces"

    static func load(from keychain: KeychainStore = KeychainStore()) -> [SlackWorkspace] {
        guard let raw = try? keychain.get(account: account),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([SlackWorkspace].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ workspaces: [SlackWorkspace], to keychain: KeychainStore = KeychainStore()) throws {
        let data = try JSONEncoder().encode(workspaces)
        let raw = String(data: data, encoding: .utf8) ?? "[]"
        try keychain.set(account: account, value: raw)
    }

    static func add(_ ws: SlackWorkspace, to keychain: KeychainStore = KeychainStore()) throws -> [SlackWorkspace] {
        var current = load(from: keychain)
        current.removeAll { $0.teamId == ws.teamId }
        current.append(ws)
        try save(current, to: keychain)
        return current
    }

    static func remove(teamId: String, from keychain: KeychainStore = KeychainStore()) throws -> [SlackWorkspace] {
        var current = load(from: keychain)
        current.removeAll { $0.teamId == teamId }
        try save(current, to: keychain)
        return current
    }
}
