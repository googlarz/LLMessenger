// LLMessenger/Core/MCP/MCPServer.swift
//
// Minimal hand-rolled MCP server: JSON-RPC 2.0, newline-delimited JSON over stdio.
// Only protocol plumbing lives here; the tools are in MCPToolbox. stdout carries
// protocol messages and nothing else.

import Foundation

struct MCPServer {
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let fallbackProtocolVersion = "2024-11-05"
    static let maxLineBytes = 1_048_576

    let toolbox: MCPToolbox

    /// Entry point for `LLMessenger --mcp`. Returns the process exit code.
    static func runStdio() -> Int32 {
        signal(SIGPIPE, SIG_IGN)   // a vanished client must end the loop, not kill us mid-write
        let server = MCPServer(toolbox: .production())
        var splitter = MCPLineSplitter(maxLineBytes: maxLineBytes)
        var chunk = [UInt8](repeating: 0, count: 65_536)

        func respond(_ items: [MCPLineSplitter.Item]) -> Bool {
            for item in items {
                let response: String?
                switch item {
                case .line(let line): response = server.handle(line: line)
                case .oversize: response = oversizeError
                }
                guard let response else { continue }
                guard fputs(response + "\n", stdout) >= 0, fflush(stdout) == 0 else { return false }
            }
            return true
        }

        while true {
            let count = read(STDIN_FILENO, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            guard respond(splitter.feed(chunk[0..<count])) else { return 0 }
        }
        _ = respond(splitter.finish())
        return 0
    }

    static let oversizeError = error(id: NSNull(), code: -32600, message: "Invalid Request: line exceeds 1 MB")

    /// Handles one inbound line; returns the response line, or nil when none is due.
    func handle(line: String) -> String? {
        if line.utf8.count > Self.maxLineBytes {
            return Self.oversizeError
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return Self.error(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let request = parsed as? [String: Any] else {
            return Self.error(id: NSNull(), code: -32600, message: "Invalid Request")
        }

        let id = request["id"]            // absent = notification: never answered
        guard let method = request["method"] as? String else {
            return id.map { Self.error(id: $0, code: -32600, message: "Invalid Request") }
        }
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return id.map { Self.result(id: $0, initializeResult(params)) }
        case "ping":
            return id.map { Self.result(id: $0, [:]) }
        case "tools/list":
            return id.map { Self.result(id: $0, ["tools": MCPToolbox.tools.map { $0.json }]) }
        case "tools/call":
            guard let id else { return nil }
            return callTool(id: id, params: request["params"])
        default:
            return id.map { Self.error(id: $0, code: -32601, message: "Method not found: \(method)") }
        }
    }

    // MARK: - Methods

    private func initializeResult(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.fallbackProtocolVersion
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return ["protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "llmessenger", "version": appVersion]]
    }

    private func callTool(id: Any, params: Any?) -> String {
        guard let params = params as? [String: Any], let name = params["name"] as? String else {
            return Self.error(id: id, code: -32602, message: "Invalid params: `name` is required")
        }
        var arguments: [String: Any] = [:]
        if let raw = params["arguments"], !(raw is NSNull) {
            guard let object = raw as? [String: Any] else {
                return Self.error(id: id, code: -32602, message: "Invalid params: `arguments` must be an object")
            }
            arguments = object
        }
        guard MCPToolbox.toolNames.contains(name) else {
            return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        let outcome = toolbox.call(tool: name, arguments: arguments)
        return Self.result(id: id, ["content": [["type": "text", "text": outcome.text]],
                                    "isError": outcome.isError])
    }

    // MARK: - Framing

    private static func result(id: Any, _ result: [String: Any]) -> String {
        MCPToolbox.compactJSON(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: Any, code: Int, message: String) -> String {
        MCPToolbox.compactJSON(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
}

/// Splits a byte stream into newline-delimited lines without ever buffering more than
/// `maxLineBytes`: an over-long line yields one `.oversize` and the rest of it is dropped.
struct MCPLineSplitter {
    enum Item: Equatable {
        case line(String)
        case oversize
    }

    let maxLineBytes: Int
    private var buffer: [UInt8] = []
    private var discarding = false

    init(maxLineBytes: Int = MCPServer.maxLineBytes) { self.maxLineBytes = maxLineBytes }

    mutating func feed<C: Collection>(_ bytes: C) -> [Item] where C.Element == UInt8 {
        var items: [Item] = []
        for byte in bytes {
            if byte == 0x0A {
                if discarding { discarding = false } else { items.append(.line(take())) }
            } else if !discarding {
                buffer.append(byte)
                if buffer.count > maxLineBytes {
                    buffer.removeAll(keepingCapacity: false)
                    discarding = true
                    items.append(.oversize)
                }
            }
        }
        return items
    }

    /// Call at EOF: a final line without a trailing newline is still a line.
    mutating func finish() -> [Item] {
        defer { buffer.removeAll(); discarding = false }
        return discarding || buffer.isEmpty ? [] : [.line(take())]
    }

    private mutating func take() -> String {
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }
}
