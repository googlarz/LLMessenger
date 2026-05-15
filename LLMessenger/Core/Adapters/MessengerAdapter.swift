import Foundation

// MARK: - Fetch Configuration

struct FetchConfig {
    enum Mode {
        case byTime(since: Date)
        case byCount(last: Int)
    }
    let mode: Mode
}

// MARK: - Adapter Response Types

struct AdapterMessage: Decodable {
    let id: String
    let sender: String
    let text: String
    let timestamp: Date
    let isFromMe: Bool

    init(id: String, sender: String, text: String, timestamp: Date, isFromMe: Bool = false) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.isFromMe = isFromMe
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sender = try container.decode(String.self, forKey: .sender)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isFromMe = try container.decodeIfPresent(Bool.self, forKey: .isFromMe) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, sender, text, timestamp, isFromMe
    }
}

enum ConversationType: String, Decodable {
    case dm
    case group
    case channel
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ConversationType(rawValue: raw) ?? .unknown
    }
}

struct AdapterConversation: Decodable {
    let id: String
    let name: String
    let type: ConversationType
    let messages: [AdapterMessage]
}

struct AdapterFetchResult {
    let conversations: [AdapterConversation]
}

struct AdapterHealthResult {
    enum Status: String, Equatable {
        case ok, warning, error
    }
    let status: Status
    let reason: String?
    let retryAfter: Int?
}

// MARK: - Errors

enum AdapterError: Error, LocalizedError {
    case notRunning
    case initFailed(String)
    case sendFailed(String)
    case invalidResponse
    case processClosed
    case timeout

    var errorDescription: String? {
        switch self {
        case .notRunning:          return "Adapter process is not running"
        case .initFailed(let r):   return "Adapter init failed: \(r)"
        case .sendFailed(let r):   return "Send failed: \(r)"
        case .invalidResponse:     return "Invalid response from adapter"
        case .processClosed:       return "Adapter process closed unexpectedly"
        case .timeout:             return "Adapter request timed out"
        }
    }
}

// MARK: - Protocol

protocol MessengerAdapter: AnyObject {
    var serviceID: String { get }
    var healthStatus: AdapterHealthResult.Status { get }

    /// Start the adapter. Must be called before fetch/send.
    func start() async throws

    /// Stop the adapter and release any resources.
    func stop()

    /// Fetch new messages according to the given config.
    func fetch(config: FetchConfig) async throws -> AdapterFetchResult

    /// Send a message to a conversation.
    func send(conversationID: String, text: String) async throws

    /// Check adapter health. Does not throw — returns error status instead.
    func healthCheck() async -> AdapterHealthResult

    /// Enumerate known contacts and group conversations for the @ mention picker.
    /// Default implementation returns an empty list — adapters opt in.
    func listContacts() async -> [Contact]
}

extension MessengerAdapter {
    func listContacts() async -> [Contact] { [] }
}
