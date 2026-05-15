import Foundation

/// Rolling in-memory record of every cloud HTTPS call the app makes during the current
/// session. Used by Settings → About → Data Flow → Network log to let the user verify
/// that egress matches the documented set in PRIVACY.md.
///
/// We never record request or response bodies — only metadata (provider, endpoint path,
/// method, status, byte count). The log resets when the app restarts.
@MainActor
final class NetworkAuditLog: ObservableObject {
    static let shared = NetworkAuditLog()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let provider: String       // "Anthropic", "OpenAI", "Slack", "Ollama (local)", etc.
        let method: String         // "POST", "GET"
        let endpoint: String       // host + path, no query (queries can contain user IDs)
        let requestBytes: Int      // request body byte count, 0 if none
        let status: Int?           // HTTP status, nil if request never completed
        let durationMs: Int?       // round-trip in milliseconds, nil on error
        let error: String?         // localizedDescription if the request threw
        let isLocal: Bool          // true for localhost (Ollama, signal-cli daemon)
    }

    @Published private(set) var entries: [Entry] = []
    private let capacity = 500

    private init() {}

    func record(_ entry: Entry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        entries = []
    }

    /// Convenience: derive an Entry from a URLRequest and timing info, then record.
    /// Safe to call from any thread — it dispatches the publish onto MainActor.
    nonisolated func record(
        provider: String,
        request: URLRequest,
        status: Int?,
        durationMs: Int?,
        error: Error?
    ) {
        let endpoint = NetworkAuditLog.compactEndpoint(request.url)
        let isLocal = NetworkAuditLog.isLocalhost(request.url)
        let entry = Entry(
            timestamp: Date(),
            provider: provider,
            method: request.httpMethod ?? "GET",
            endpoint: endpoint,
            requestBytes: request.httpBody?.count ?? 0,
            status: status,
            durationMs: durationMs,
            error: error?.localizedDescription,
            isLocal: isLocal
        )
        Task { @MainActor in
            NetworkAuditLog.shared.record(entry)
        }
    }

    private nonisolated static func compactEndpoint(_ url: URL?) -> String {
        guard let url else { return "?" }
        // host + path; drop query string because it can carry user IDs / cursors.
        let host = url.host ?? ""
        let path = url.path
        return host + path
    }

    private nonisolated static func isLocalhost(_ url: URL?) -> Bool {
        guard let host = url?.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
