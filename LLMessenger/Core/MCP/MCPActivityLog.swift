// LLMessenger/Core/MCP/MCPActivityLog.swift
//
// "Last agent request": when an MCP tool call last reached a tool, and which tool.
// The `--mcp` helper process writes it and the GUI app reads it, through the same
// defaults domain (the helper is the app's own binary, so `.standard` is shared).
//
// Privacy: only the tool name and the time are stored — never arguments, queries,
// conversation ids or results.

import Foundation

struct MCPActivityLog: @unchecked Sendable {
    static let lastCallAtKey = "mcp_last_call_at"
    static let lastCallToolKey = "mcp_last_call_tool"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(tool: String, at date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastCallAtKey)
        defaults.set(tool, forKey: Self.lastCallToolKey)
        flush()
    }

    func load() -> (date: Date, tool: String)? {
        // Pull what the other process wrote (cfprefsd caches per process).
        if defaults === UserDefaults.standard { CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication) }
        guard let seconds = defaults.object(forKey: Self.lastCallAtKey) as? Double,
              let tool = defaults.string(forKey: Self.lastCallToolKey) else { return nil }
        return (Date(timeIntervalSince1970: seconds), tool)
    }

    func clear() {
        defaults.removeObject(forKey: Self.lastCallAtKey)
        defaults.removeObject(forKey: Self.lastCallToolKey)
        flush()
    }

    /// The helper exits when the agent disconnects; push the write out before then.
    private func flush() {
        if defaults === UserDefaults.standard { CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication) }
    }
}
