import Foundation

final class SubprocessAdapter: MessengerAdapter {
    let serviceID: String
    private(set) var healthStatus: AdapterHealthResult.Status = .ok

    private let adapterPath: String
    private let adapterArgs: [String]
    private let config: [String: Any]

    private var process: Process?
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?

    private let ioQueue: DispatchQueue

    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(serviceID: String, adapterPath: String,
         adapterArgs: [String] = [], config: [String: Any]) {
        self.serviceID = serviceID
        self.adapterPath = adapterPath
        self.adapterArgs = adapterArgs
        self.config = config
        self.ioQueue = DispatchQueue(label: "com.llmessenger.adapter.\(serviceID)")
    }

    func start() async throws {
        try launchProcess()
        try await sendInit()
    }

    private func launchProcess() throws {
        guard process == nil else { return }
        let p = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()

        p.executableURL = URL(fileURLWithPath: adapterPath)
        p.arguments = adapterArgs
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()

        p.terminationHandler = { [weak self] _ in
            self?.healthStatus = .error
        }

        try p.run()
        process = p
        writeHandle = inPipe.fileHandleForWriting
        readHandle = outPipe.fileHandleForReading
    }

    private func sendInit() async throws {
        let response = try await roundTrip(["action": "init", "config": config])
        guard response["success"] as? Bool == true else {
            let reason = response["error"] as? String ?? "unknown"
            throw AdapterError.initFailed(reason)
        }
    }

    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        var req: [String: Any] = ["action": "fetch"]
        switch config.mode {
        case .byTime(let since):
            req["mode"] = "time"
            req["since"] = iso8601.string(from: since)
        case .byCount(let last):
            req["mode"] = "count"
            req["limit"] = last
        }

        let response = try await roundTrip(req)
        let data = try JSONSerialization.data(withJSONObject: response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(FetchPayload.self, from: data)
        return AdapterFetchResult(conversations: payload.conversations)
    }

    func send(conversationID: String, text: String) async throws {
        let response = try await roundTrip([
            "action": "send",
            "conversation_id": conversationID,
            "text": text
        ])
        guard response["success"] as? Bool == true else {
            let reason = response["error"] as? String ?? "unknown"
            throw AdapterError.sendFailed(reason)
        }
    }

    func healthCheck() async -> AdapterHealthResult {
        do {
            let response = try await roundTrip(["action": "health"])
            let statusStr = response["status"] as? String ?? "error"
            let status = AdapterHealthResult.Status(rawValue: statusStr) ?? .error
            healthStatus = status
            return AdapterHealthResult(
                status: status,
                reason: response["reason"] as? String,
                retryAfter: response["retry_after"] as? Int
            )
        } catch {
            healthStatus = .error
            return AdapterHealthResult(status: .error,
                                       reason: error.localizedDescription,
                                       retryAfter: nil)
        }
    }

    private func roundTrip(_ request: [String: Any]) async throws -> [String: Any] {
        guard process?.isRunning == true,
              let writeHandle, let readHandle else {
            throw AdapterError.notRunning
        }

        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    var data = try JSONSerialization.data(withJSONObject: request)
                    data.append(UInt8(ascii: "\n"))
                    writeHandle.write(data)

                    var buffer = Data()
                    while true {
                        let byte = readHandle.readData(ofLength: 1)
                        if byte.isEmpty {
                            continuation.resume(throwing: AdapterError.processClosed)
                            return
                        }
                        if byte[0] == UInt8(ascii: "\n") { break }
                        buffer.append(contentsOf: byte)
                    }

                    guard let response = try JSONSerialization.jsonObject(with: buffer)
                            as? [String: Any] else {
                        continuation.resume(throwing: AdapterError.invalidResponse)
                        return
                    }
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct FetchPayload: Decodable {
    let conversations: [AdapterConversation]
}
