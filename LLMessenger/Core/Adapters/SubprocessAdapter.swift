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
    private let readBuffer = _IOBuffer()

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
        self.ioQueue = DispatchQueue(label: "com.llmessenger.adapter.\(serviceID)", qos: .userInitiated)
    }

    func start() async throws {
        guard process?.isRunning != true else { return }
        try launchProcess()
        try await sendInit()
    }

    func stop() {
        process?.terminate()
        writeHandle = nil
        readHandle = nil
        process = nil
        readBuffer.data.removeAll()
        healthStatus = .warning
    }

    private func launchProcess() throws {
        // Allow relaunch if the previous process has already exited.
        if let existing = process, existing.isRunning { return }
        process = nil; writeHandle = nil; readHandle = nil
        readBuffer.data.removeAll()
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

    func authRoundTrip(_ request: [String: Any]) async throws -> [String: Any] {
        try await roundTrip(request)
    }

    private func roundTrip(_ request: [String: Any]) async throws -> [String: Any] {
        guard process?.isRunning == true,
              let writeHandle, let readHandle else {
            throw AdapterError.notRunning
        }

        // Capture as a local ref so the closure doesn't need to retain self.
        let readBuffer = self.readBuffer

        // ioQueue.async blocks the serial queue thread until sem.signal() fires,
        // preventing concurrent roundTrips from clobbering readabilityHandler.
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                let sem = DispatchSemaphore(value: 0)
                var callResult: Result<[String: Any], Error>?

                do {
                    var data = try JSONSerialization.data(withJSONObject: request)
                    data.append(UInt8(ascii: "\n"))
                    writeHandle.write(data)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Slice one newline-terminated line from the shared buffer.
                // Bytes after the newline are left in place for the next call.
                let consumeLine: () -> Bool = {
                    guard let nlIdx = readBuffer.data.firstIndex(of: UInt8(ascii: "\n")) else { return false }
                    let line = readBuffer.data[..<nlIdx]
                    readBuffer.data = Data(readBuffer.data[readBuffer.data.index(after: nlIdx)...])
                    if let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        callResult = .success(response)
                    } else {
                        callResult = .failure(AdapterError.invalidResponse)
                    }
                    return true
                }

                // A previous call may have left a complete line in the buffer.
                if consumeLine() {
                    sem.signal()
                } else {
                    readHandle.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            callResult = .failure(AdapterError.processClosed)
                            handle.readabilityHandler = nil
                            sem.signal()
                            return
                        }
                        readBuffer.data.append(chunk)
                        if consumeLine() {
                            handle.readabilityHandler = nil
                            sem.signal()
                        }
                    }
                }

                if sem.wait(timeout: .now() + 30) == .timedOut {
                    readHandle.readabilityHandler = nil
                    continuation.resume(throwing: AdapterError.timeout)
                } else {
                    switch callResult ?? .failure(AdapterError.processClosed) {
                    case .success(let r): continuation.resume(returning: r)
                    case .failure(let e): continuation.resume(throwing: e)
                    }
                }
            }
        }
    }
}

// readabilityHandler fires on a private serial queue — safe without external locking.
private final class _IOBuffer: @unchecked Sendable { var data = Data() }

private struct FetchPayload: Decodable {
    let conversations: [AdapterConversation]
}
