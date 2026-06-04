import Foundation

final class SubprocessAdapter: MessengerAdapter {
    let serviceID: String
    // .warning until start() has successfully completed. Matters because
    // PollEngine.pollOnce only calls adapter.start() when healthStatus != .ok;
    // if we default to .ok the subprocess never spawns and fetch() throws
    // .notRunning. The other three adapters (iMessage/Signal/Slack) also
    // default to .warning for the same reason.
    private(set) var healthStatus: AdapterHealthResult.Status = .warning

    private let adapterPath: String
    private let adapterArgs: [String]
    private let config: [String: Any]

    private var process: Process?
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?
    private var stderrHandle: FileHandle?

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
        self.ioQueue = DispatchQueue(label: "com.llmessenger.adapter.\(serviceID)", qos: .default)
    }

    deinit {
        process?.terminate()
    }

    func start() async throws {
        guard process?.isRunning != true else { return }
        do {
            try launchProcess()
            try await sendInit()
            // Flip to .ok so PollEngine.pollOnce stops retrying start() and
            // moves on to fetch() on subsequent polls.
            healthStatus = .ok
        } catch {
            // Drain stderr before stop() clears the handle, then terminate the process.
            let detail = drainStderr()
            stop()
            healthStatus = .error
            if !detail.isEmpty {
                throw AdapterError.initFailed("\(error.localizedDescription)\n\(detail)")
            }
            throw error
        }
    }

    /// Non-blocking read of whatever stderr has accumulated since start.
    /// Strips lines containing credentials and returns only the first
    /// meaningful error line so tracebacks don't leak secrets into the UI.
    private func drainStderr() -> String {
        guard let handle = stderrHandle else { return "" }
        let data = handle.availableData
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return "" }
        return sanitizeStderr(text)
    }

    private func sanitizeStderr(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        let safe = lines.filter { line in
            let lower = line.lowercased()
            return !lower.contains("api_id") &&
                   !lower.contains("api_hash") &&
                   !lower.contains("secret") &&
                   !lower.contains("token")
        }
        return safe.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    }

    func stop() {
        // SIGTERM, then wait until the process actually exits and closes its
        // file handles. Without this wait, a fast respawn (e.g. user clicks
        // Retry now twice or registerAdapter is called twice) races the old
        // process for any single-writer resources — Pyrogram's
        // session.session SQLite file is the canonical example, where the
        // second adapter sees "database is locked" because the first still
        // holds the descriptor.
        if let p = process {
            p.terminate()
            // Give it a graceful 2s, then SIGKILL.
            let deadline = Date().addingTimeInterval(2.0)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                p.waitUntilExit()
            }
        }
        writeHandle = nil
        readHandle = nil
        stderrHandle = nil
        process = nil
        readBuffer.data.removeAll()
        healthStatus = .warning
    }

    private func launchProcess() throws {
        // Allow relaunch if the previous process has already exited.
        if let existing = process, existing.isRunning { return }
        process = nil; writeHandle = nil; readHandle = nil; stderrHandle = nil
        readBuffer.data.removeAll()
        let p = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        p.executableURL = URL(fileURLWithPath: adapterPath)
        p.arguments = adapterArgs
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        p.terminationHandler = { [weak self] _ in
            self?.healthStatus = .error
        }

        try p.run()
        process = p
        writeHandle = inPipe.fileHandleForWriting
        readHandle = outPipe.fileHandleForReading
        // Keep the stderr handle so drainStderr() can read it on start failure.
        stderrHandle = errPipe.fileHandleForReading
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

        let response = try await roundTrip(req, timeout: 300)
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

    func listContacts() async -> [Contact] {
        // The remote adapter implements a `contacts` action that returns an array of
        // {id, display_name, is_group}. Falls back to empty if the adapter doesn't
        // support it (older versions, missing implementation, or daemon offline).
        guard let response = try? await roundTrip(["action": "contacts"], timeout: 10),
              response["success"] as? Bool == true,
              let raw = response["contacts"] as? [[String: Any]] else {
            return []
        }
        let svc = serviceID
        return raw.compactMap { entry -> Contact? in
            guard let convId = entry["id"] as? String, !convId.isEmpty,
                  let name = entry["display_name"] as? String, !name.isEmpty
            else { return nil }
            let isGroup = (entry["is_group"] as? Bool) ?? false
            return Contact(
                id: "\(svc):\(isGroup ? "group" : "dm"):\(convId)",
                displayName: name,
                handles: [ServiceHandle(service: svc, conversationId: convId, isGroup: isGroup)]
            )
        }
    }

    func authRoundTrip(_ request: [String: Any]) async throws -> [String: Any] {
        try await roundTrip(request)
    }

    private func roundTrip(_ request: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard process?.isRunning == true,
              let writeHandle, let readHandle else {
            throw AdapterError.notRunning
        }

        // Capture as a local ref so the closure doesn't need to retain self.
        let readBuffer = self.readBuffer

        // Shared state hoisted so both the operation and onCancel closures can reference it.
        final class RoundTripState: @unchecked Sendable {
            let sem = DispatchSemaphore(value: 0)
            var cancelled = false
            var result: Result<[String: Any], Error>?
        }
        let state = RoundTripState()

        // withTaskCancellationHandler wraps withCheckedThrowingContinuation so that
        // if the calling Task is cancelled while ioQueue.async is blocked on the
        // semaphore, onCancel signals the semaphore and allows the continuation to
        // resume with CancellationError instead of leaking indefinitely.
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    ioQueue.async {
                        // Abort early if already cancelled before we even started.
                        guard !state.cancelled else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }

                        do {
                            var data = try JSONSerialization.data(withJSONObject: request)
                            data.append(UInt8(ascii: "\n"))
                            // Modern throwing API: a dead pipe surfaces as a Swift error
                            // (NSCocoaErrorDomain / EPIPE) instead of an uncatchable NSException.
                            // The legacy writeData(_:) raises an ObjC exception that crashes Swift.
                            try writeHandle.write(contentsOf: data)
                        } catch {
                            continuation.resume(throwing: AdapterError.processClosed)
                            return
                        }

                        // Slice one newline-terminated line from the shared buffer.
                        // Bytes after the newline are left in place for the next call.
                        let consumeLine: () -> Bool = {
                            guard let nlIdx = readBuffer.data.firstIndex(of: UInt8(ascii: "\n")) else { return false }
                            let line = readBuffer.data[..<nlIdx]
                            readBuffer.data = Data(readBuffer.data[readBuffer.data.index(after: nlIdx)...])
                            if let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                                state.result = .success(response)
                            } else {
                                state.result = .failure(AdapterError.invalidResponse)
                            }
                            return true
                        }

                        // A previous call may have left a complete line in the buffer.
                        if consumeLine() {
                            state.sem.signal()
                        } else {
                            readHandle.readabilityHandler = { handle in
                                let chunk = handle.availableData
                                if chunk.isEmpty {
                                    state.result = .failure(AdapterError.processClosed)
                                    handle.readabilityHandler = nil
                                    state.sem.signal()
                                    return
                                }
                                readBuffer.data.append(chunk)
                                if consumeLine() {
                                    handle.readabilityHandler = nil
                                    state.sem.signal()
                                }
                            }
                        }

                        if state.sem.wait(timeout: .now() + timeout) == .timedOut {
                            readHandle.readabilityHandler = nil
                            continuation.resume(throwing: AdapterError.timeout)
                        } else if state.cancelled {
                            readHandle.readabilityHandler = nil
                            continuation.resume(throwing: CancellationError())
                        } else {
                            switch state.result ?? .failure(AdapterError.processClosed) {
                            case .success(let r): continuation.resume(returning: r)
                            case .failure(let e): continuation.resume(throwing: e)
                            }
                        }
                    }
                }
            },
            onCancel: {
                // Signal the semaphore so ioQueue.async unblocks and resumes the
                // continuation with CancellationError. Called from an arbitrary thread;
                // RoundTripState is @unchecked Sendable — the semaphore provides the
                // necessary happens-before relationship.
                state.cancelled = true
                state.sem.signal()
            }
        )
    }
}

// readabilityHandler fires on a private serial queue — safe without external locking.
private final class _IOBuffer: @unchecked Sendable { var data = Data() }

private struct FetchPayload: Decodable {
    let conversations: [AdapterConversation]
}
