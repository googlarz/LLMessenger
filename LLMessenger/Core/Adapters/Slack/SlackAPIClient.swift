import Foundation

/// Slack's Web API returns HTTP 200 even when a call fails — failure is signaled by
/// `"ok": false` plus a machine-readable `error` code in the body. `.authFailed` is a
/// specific subset of `.apiError` for the codes Slack documents as requiring the user
/// to reconnect (as opposed to a transient issue worth just retrying).
enum SlackAPIError: Error, LocalizedError {
    case authFailed(code: String)
    case apiError(code: String)

    /// https://api.slack.com/methods/auth.test — codes that mean the token itself
    /// is no longer usable, not a transient hiccup.
    private static let authFailureCodes: Set<String> = [
        "invalid_auth", "token_revoked", "account_inactive",
        "token_expired", "not_authed", "no_permission"
    ]

    static func from(code: String) -> SlackAPIError {
        authFailureCodes.contains(code) ? .authFailed(code: code) : .apiError(code: code)
    }

    var errorDescription: String? {
        switch self {
        case .authFailed(let code):
            return "Slack authentication expired (\(code)) — reconnect this workspace in Settings."
        case .apiError(let code):
            return "Slack API error: \(code)"
        }
    }
}

/// Thin HTTPS wrapper for the Slack Web API. One instance per workspace.
/// All methods POST form-urlencoded and decode the standard {"ok": Bool, ...} envelope.
/// Rate limiting: Slack publishes per-method tiers (T3 = ~50/min). We serialise calls
/// per (workspace, method) with a 1.2s minimum gap, which keeps us well under T3 while
/// trading throughput for safety.
final class SlackAPIClient {
    let workspace: SlackWorkspace
    private let session: URLSession
    private let baseURL = URL(string: "https://slack.com/api/")!
    private var lastCallByMethod: [String: Date] = [:]
    private let lock = NSLock()
    private let minGap: TimeInterval = 1.2

    init(workspace: SlackWorkspace, session: URLSession = .shared) {
        self.workspace = workspace
        self.session = session
    }

    // MARK: - Public methods

    struct AuthTest: Decodable {
        let ok: Bool
        let url: String?
        let team: String?
        let user: String?
        let team_id: String?
        let user_id: String?
        let error: String?
    }

    struct Conversation: Decodable {
        let id: String
        let name: String?
        let is_im: Bool?
        let is_mpim: Bool?
        let is_group: Bool?
        let is_channel: Bool?
        let is_private: Bool?
        let is_archived: Bool?
        let user: String?            // IM partner user_id
        let topic: Topic?

        struct Topic: Decodable { let value: String? }

        var isDM: Bool { is_im ?? false }
        var isGroup: Bool { is_group ?? false || is_mpim ?? false }
        var isChannel: Bool { is_channel ?? false }
    }

    struct HistoryMessage: Decodable {
        let ts: String
        let user: String?
        let bot_id: String?
        let text: String?
        let subtype: String?
        let username: String?
    }

    struct UserInfo: Decodable {
        let id: String
        let team_id: String?
        let name: String?
        let deleted: Bool?
        let profile: Profile?
        struct Profile: Decodable {
            let real_name: String?
            let display_name: String?
            let email: String?
        }
        var bestName: String {
            if let dn = profile?.display_name, !dn.isEmpty { return dn }
            if let rn = profile?.real_name, !rn.isEmpty { return rn }
            return name ?? id
        }
    }

    func authTest() async throws -> AuthTest {
        try await call("auth.test", params: [:], decode: AuthTest.self)
    }

    /// Conversations the authed user is a member of, paginated. Returns all pages joined.
    func usersConversations(types: String = "public_channel,private_channel,im,mpim",
                            excludeArchived: Bool = true) async throws -> [Conversation] {
        struct Page: Decodable {
            let ok: Bool
            let channels: [Conversation]?
            let response_metadata: Meta?
            let error: String?
            struct Meta: Decodable { let next_cursor: String? }
        }
        var all: [Conversation] = []
        var cursor: String? = nil
        repeat {
            var params: [String: String] = [
                "types": types,
                "exclude_archived": excludeArchived ? "true" : "false",
                "limit": "200"
            ]
            if let c = cursor, !c.isEmpty { params["cursor"] = c }
            let page = try await call("users.conversations", params: params, decode: Page.self)
            all.append(contentsOf: page.channels ?? [])
            cursor = page.response_metadata?.next_cursor
        } while !(cursor?.isEmpty ?? true)
        return all
    }

    /// Recent messages in a conversation since `oldestTs` (Slack timestamp string, e.g. "1700000000.000100").
    /// Returns chronologically ordered (oldest first).
    func conversationsHistory(channelId: String, oldestTs: String?, limit: Int = 200) async throws -> [HistoryMessage] {
        struct Page: Decodable {
            let ok: Bool
            let messages: [HistoryMessage]?
            let has_more: Bool?
            let response_metadata: Meta?
            let error: String?
            struct Meta: Decodable { let next_cursor: String? }
        }
        var all: [HistoryMessage] = []
        var cursor: String? = nil
        repeat {
            var params: [String: String] = [
                "channel": channelId,
                "limit": String(limit),
                "inclusive": "false"
            ]
            if let oldest = oldestTs, !oldest.isEmpty { params["oldest"] = oldest }
            if let c = cursor, !c.isEmpty { params["cursor"] = c }
            let page = try await call("conversations.history", params: params, decode: Page.self)
            all.append(contentsOf: page.messages ?? [])
            cursor = page.response_metadata?.next_cursor
        } while !(cursor?.isEmpty ?? true)
        // Slack returns newest first; we want oldest first for downstream ordering.
        return all.reversed()
    }

    /// Send a plain-text message to a channel/DM/group.
    func chatPostMessage(channelId: String, text: String) async throws {
        // ok:false is now caught generically inside call() and thrown as
        // SlackAPIError before this decode ever sees a failure response.
        struct Resp: Decodable { let ok: Bool }
        _ = try await call("chat.postMessage",
                           params: ["channel": channelId, "text": text],
                           decode: Resp.self)
    }

    /// All users in the workspace. Used to build the @ mention picker and resolve sender_id → name.
    func usersList() async throws -> [UserInfo] {
        struct Page: Decodable {
            let ok: Bool
            let members: [UserInfo]?
            let response_metadata: Meta?
            let error: String?
            struct Meta: Decodable { let next_cursor: String? }
        }
        var all: [UserInfo] = []
        var cursor: String? = nil
        repeat {
            var params: [String: String] = ["limit": "200"]
            if let c = cursor, !c.isEmpty { params["cursor"] = c }
            let page = try await call("users.list", params: params, decode: Page.self)
            all.append(contentsOf: page.members ?? [])
            cursor = page.response_metadata?.next_cursor
        } while !(cursor?.isEmpty ?? true)
        return all
    }

    // MARK: - Low level

    private func call<T: Decodable>(_ method: String,
                                    params: [String: String],
                                    decode: T.Type,
                                    attempt: Int = 0) async throws -> T {
        try await pace(method: method)
        var req = URLRequest(url: baseURL.appendingPathComponent(method))
        req.httpMethod = "POST"
        req.setValue("Bearer \(workspace.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(params).data(using: .utf8)
        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            NetworkAuditLog.shared.record(provider: "Slack", request: req,
                                          status: nil, durationMs: ms, error: error)
            throw error
        }
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        guard let http = response as? HTTPURLResponse else {
            NetworkAuditLog.shared.record(provider: "Slack", request: req,
                                          status: nil, durationMs: durationMs, error: nil)
            throw AdapterError.invalidResponse
        }
        NetworkAuditLog.shared.record(provider: "Slack", request: req,
                                      status: http.statusCode, durationMs: durationMs, error: nil)
        if http.statusCode == 429 {
            guard attempt < 3 else { throw AdapterError.invalidResponse }
            // Honor Retry-After if present, otherwise wait 2s.
            let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
            try await Task.sleep(nanoseconds: UInt64(retry) * 1_000_000_000)
            try Task.checkCancellation()
            return try await self.call(method, params: params, decode: decode, attempt: attempt + 1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AdapterError.invalidResponse
        }
        // Slack signals API-level failure with HTTP 200 + "ok": false — a decode
        // into T alone can't see this (T's fields are typically all-optional, so
        // an auth failure with an empty body would otherwise decode "successfully"
        // into a default/empty T and silently look like zero results).
        if let envelope = try? JSONDecoder().decode(SlackEnvelope.self, from: data), !envelope.ok {
            throw SlackAPIError.from(code: envelope.error ?? "unknown_error")
        }
        do {
            return try JSONDecoder().decode(decode, from: data)
        } catch {
            throw AdapterError.invalidResponse
        }
    }

    private struct SlackEnvelope: Decodable {
        let ok: Bool
        let error: String?
    }

    private func pace(method: String) async throws {
        let now = Date()
        lock.lock()
        let last = lastCallByMethod[method]
        let wait: TimeInterval
        if let last {
            let elapsed = now.timeIntervalSince(last)
            wait = max(0, minGap - elapsed)
        } else {
            wait = 0
        }
        lastCallByMethod[method] = now.addingTimeInterval(wait)
        lock.unlock()
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    private func formEncode(_ params: [String: String]) -> String {
        params.map { k, v in
            let kk = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let vv = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(kk)=\(vv)"
        }.joined(separator: "&")
    }
}
