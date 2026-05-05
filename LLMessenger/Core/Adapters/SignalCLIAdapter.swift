// LLMessenger/Core/Adapters/SignalCLIAdapter.swift
import Foundation

final class SignalCLIAdapter: MessengerAdapter {
    let serviceID = "signal"
    private(set) var healthStatus: AdapterHealthResult.Status = .warning

    private let accountNumber: String
    private let cliPath: String

    init(accountNumber: String, cliPath: String) {
        self.accountNumber = accountNumber
        self.cliPath = cliPath
    }

    static func detectCLIPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/signal-cli",
            "/usr/local/bin/signal-cli"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - MessengerAdapter

    func start() async throws {
        guard FileManager.default.fileExists(atPath: cliPath) else {
            throw AdapterError.initFailed("signal-cli not found at \(cliPath)")
        }
        healthStatus = .ok
    }

    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        let lines = try runCLI(args: ["-a", accountNumber, "receive", "--output", "json"])
        let conversations = Self.parse(lines: lines)
        return AdapterFetchResult(conversations: conversations)
    }

    func send(conversationID: String, text: String) async throws {
        let isGroup = !conversationID.hasPrefix("+")
        var args = ["-a", accountNumber, "send", "-m", text]
        if isGroup {
            args += ["--group-id", conversationID]
        } else {
            args.append(conversationID)
        }
        _ = try runCLI(args: args)
    }

    func healthCheck() async -> AdapterHealthResult {
        guard FileManager.default.fileExists(atPath: cliPath) else {
            healthStatus = .error
            return AdapterHealthResult(status: .error, reason: "signal-cli not found", retryAfter: nil)
        }
        healthStatus = .ok
        return AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil)
    }

    // MARK: - Parsing (static for testability)

    static func parse(lines: [String]) -> [AdapterConversation] {
        var byID: [String: (name: String, type: ConversationType, messages: [AdapterMessage])] = [:]
        var order: [String] = []
        let decoder = JSONDecoder()

        for line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  let root = try? decoder.decode(SignalEnvelope.self, from: data),
                  let dm = root.envelope.dataMessage,
                  let text = dm.message, !text.isEmpty
            else { continue }

            let env = root.envelope
            let senderName = env.sourceName ?? env.sourceNumber ?? env.source
            let timestampMs = dm.timestamp ?? env.timestamp
            let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
            let msgID = "\(env.source)-\(timestampMs)"

            let msg = AdapterMessage(id: msgID, sender: senderName, text: text, timestamp: date)

            let convID: String
            let convName: String
            let convType: ConversationType

            if let g = dm.groupInfo {
                convID = g.groupId
                convName = g.name ?? g.groupId
                convType = .group
            } else {
                convID = env.sourceNumber ?? env.source
                convName = senderName
                convType = .dm
            }

            if byID[convID] == nil {
                byID[convID] = (name: convName, type: convType, messages: [])
                order.append(convID)
            }
            byID[convID]!.messages.append(msg)
        }

        return order.compactMap { id in
            guard let entry = byID[id] else { return nil }
            return AdapterConversation(id: id, name: entry.name,
                                       type: entry.type, messages: entry.messages)
        }
    }

    // MARK: - Private

    private func runCLI(args: [String]) throws -> [String] {
        let p = Process()
        let out = Pipe()
        let err = Pipe()
        p.executableURL = URL(fileURLWithPath: cliPath)
        p.arguments = args
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.components(separatedBy: "\n")
    }
}

// MARK: - signal-cli JSON types

private struct SignalEnvelope: Decodable {
    let envelope: Envelope

    struct Envelope: Decodable {
        let source: String
        let sourceNumber: String?
        let sourceName: String?
        let sourceDevice: Int?
        let timestamp: Int64
        let dataMessage: DataMessage?
    }

    struct DataMessage: Decodable {
        let timestamp: Int64?
        let message: String?
        let groupInfo: GroupInfo?
    }

    struct GroupInfo: Decodable {
        let groupId: String
        let name: String?
        let type: String?
    }
}
