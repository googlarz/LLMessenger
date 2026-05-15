import Foundation

/// Multi-workspace Slack adapter. Each workspace has its own xoxp- token in the Keychain,
/// and we serialise fetch work per workspace to stay inside Slack's per-method rate limits.
///
/// Conversation IDs are encoded as "<team_id>/<channel_id>" so PollEngine and BriefEngine
/// see flat strings while the adapter can still find the right workspace token on send.
final class SlackAdapter: MessengerAdapter {
    let serviceID = "slack"
    private(set) var healthStatus: AdapterHealthResult.Status = .warning

    private var clients: [String: SlackAPIClient] = [:]     // teamId → client
    private var userCache: [String: [String: SlackAPIClient.UserInfo]] = [:]  // teamId → (userId → user)
    private let recentActivityWindow: TimeInterval = 7 * 24 * 3600

    init() { reloadWorkspaces() }

    /// Refresh the underlying client list from the Keychain. Called on start() and
    /// when the user adds/removes a workspace in Settings.
    func reloadWorkspaces() {
        let workspaces = SlackWorkspaceStore.load()
        var newClients: [String: SlackAPIClient] = [:]
        for ws in workspaces {
            newClients[ws.teamId] = SlackAPIClient(workspace: ws)
        }
        clients = newClients
    }

    // MARK: - MessengerAdapter

    func start() async throws {
        reloadWorkspaces()
        guard !clients.isEmpty else {
            throw AdapterError.initFailed("No Slack workspaces configured. Add a workspace in Settings → Services.")
        }
        // Validate each token; drop any that fail rather than aborting the whole adapter.
        var living: [String: SlackAPIClient] = [:]
        for (teamId, client) in clients {
            do {
                let res = try await client.authTest()
                if res.ok { living[teamId] = client }
            } catch {
                // Skip — healthCheck will surface the failure on the next cycle.
                continue
            }
        }
        clients = living
        healthStatus = clients.isEmpty ? .warning : .ok
    }

    func stop() {
        clients = [:]
        userCache = [:]
        healthStatus = .warning
    }

    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        let since: Date
        switch config.mode {
        case .byTime(let s): since = s
        case .byCount:       since = Date().addingTimeInterval(-recentActivityWindow)
        }
        let oldestTs = String(format: "%.6f", since.timeIntervalSince1970)
        let cutoff = Date().addingTimeInterval(-recentActivityWindow)

        var aggregated: [AdapterConversation] = []
        for (teamId, client) in clients {
            do {
                // Prime user cache so sender resolution and listContacts share data.
                if userCache[teamId] == nil {
                    let users = (try? await client.usersList()) ?? []
                    userCache[teamId] = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
                }
                let convos = try await client.usersConversations()
                for convo in convos {
                    let messages = try await client.conversationsHistory(channelId: convo.id, oldestTs: oldestTs)
                    let filtered = messages.filter {
                        // Skip bot/system noise — keep human messages with non-empty text.
                        $0.subtype == nil && ($0.text ?? "").isEmpty == false
                    }
                    // "Active in last 7 days" filter: drop conversations where no message
                    // exists past the cutoff (cheap signal beyond what users.conversations gives).
                    let mostRecent = filtered.last.flatMap { Self.tsToDate($0.ts) } ?? .distantPast
                    if mostRecent < cutoff && filtered.isEmpty { continue }
                    if filtered.isEmpty { continue }

                    let workspaceName = client.workspace.teamName
                    let conv = Self.buildConversation(
                        teamId: teamId,
                        workspaceName: workspaceName,
                        convo: convo,
                        messages: filtered,
                        users: userCache[teamId] ?? [:],
                        myUserId: client.workspace.userId
                    )
                    aggregated.append(conv)
                }
            } catch {
                // Skip this workspace this cycle; healthCheck will surface persistent issues.
                continue
            }
        }
        return AdapterFetchResult(conversations: aggregated)
    }

    func send(conversationID: String, text: String) async throws {
        guard let (teamId, channelId) = Self.decodeConversationID(conversationID),
              let client = clients[teamId] else {
            throw AdapterError.sendFailed("Slack workspace for conversation \(conversationID) is not configured")
        }
        try await client.chatPostMessage(channelId: channelId, text: text)
    }

    func healthCheck() async -> AdapterHealthResult {
        guard !clients.isEmpty else {
            healthStatus = .warning
            return AdapterHealthResult(status: .warning, reason: "No Slack workspaces configured", retryAfter: nil)
        }
        var failed: [String] = []
        for (_, client) in clients {
            if (try? await client.authTest())?.ok != true {
                failed.append(client.workspace.teamName)
            }
        }
        if failed.isEmpty {
            healthStatus = .ok
            return AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil)
        }
        healthStatus = .warning
        return AdapterHealthResult(
            status: .warning,
            reason: "Slack auth failed for: \(failed.joined(separator: ", "))",
            retryAfter: nil
        )
    }

    func listContacts() async -> [Contact] {
        var contacts: [Contact] = []
        for (teamId, client) in clients {
            // Refresh user cache so contact picker reflects new joiners.
            let users = (try? await client.usersList()) ?? []
            userCache[teamId] = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })

            let workspaceName = client.workspace.teamName
            let convos = (try? await client.usersConversations()) ?? []

            // 1. DM partners → one contact per user.
            for convo in convos where convo.isDM {
                guard let partnerId = convo.user,
                      let user = userCache[teamId]?[partnerId],
                      user.deleted != true,
                      user.id != client.workspace.userId
                else { continue }
                let convID = Self.encodeConversationID(teamId: teamId, channelId: convo.id)
                contacts.append(Contact(
                    id: "slack:dm:\(convID)",
                    displayName: "\(user.bestName) (\(workspaceName))",
                    handles: [ServiceHandle(service: serviceID, conversationId: convID, isGroup: false)]
                ))
            }

            // 2. Channels/groups → one contact per channel, prefixed with #.
            for convo in convos where convo.isChannel || convo.isGroup {
                let name = convo.name.flatMap { $0.isEmpty ? nil : $0 } ?? "channel"
                let convID = Self.encodeConversationID(teamId: teamId, channelId: convo.id)
                contacts.append(Contact(
                    id: "slack:group:\(convID)",
                    displayName: "#\(name) (\(workspaceName))",
                    handles: [ServiceHandle(service: serviceID, conversationId: convID, isGroup: true)]
                ))
            }
        }
        return contacts
    }

    // MARK: - Helpers (static for testability)

    static func encodeConversationID(teamId: String, channelId: String) -> String {
        "\(teamId)/\(channelId)"
    }

    static func decodeConversationID(_ raw: String) -> (teamId: String, channelId: String)? {
        let parts = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    static func tsToDate(_ ts: String) -> Date? {
        guard let secs = Double(ts) else { return nil }
        return Date(timeIntervalSince1970: secs)
    }

    static func buildConversation(
        teamId: String,
        workspaceName: String,
        convo: SlackAPIClient.Conversation,
        messages: [SlackAPIClient.HistoryMessage],
        users: [String: SlackAPIClient.UserInfo],
        myUserId: String
    ) -> AdapterConversation {
        let convId = encodeConversationID(teamId: teamId, channelId: convo.id)
        let type: ConversationType
        let title: String
        if convo.isDM {
            type = .dm
            if let partnerId = convo.user, let partner = users[partnerId] {
                title = "\(partner.bestName) (\(workspaceName))"
            } else {
                title = "DM (\(workspaceName))"
            }
        } else if convo.isGroup {
            type = .group
            title = "#\(convo.name ?? "group") (\(workspaceName))"
        } else {
            type = .group   // public channel — treated as group for brief grouping
            title = "#\(convo.name ?? "channel") (\(workspaceName))"
        }

        let adapterMessages: [AdapterMessage] = messages.compactMap { msg in
            guard let userId = msg.user, let text = msg.text, !text.isEmpty else { return nil }
            let isFromMe = userId == myUserId
            let senderName = isFromMe ? "Me" : (users[userId]?.bestName ?? userId)
            guard let timestamp = tsToDate(msg.ts) else { return nil }
            // Use ts as the message_id — it's unique per channel.
            return AdapterMessage(
                id: "\(convo.id)-\(msg.ts)",
                sender: senderName,
                text: text,
                timestamp: timestamp,
                isFromMe: isFromMe
            )
        }

        return AdapterConversation(id: convId, name: title, type: type, messages: adapterMessages)
    }
}
