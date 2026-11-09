// LLMessenger/UI/Settings/MCPAccessModel.swift
//
// The "let AI apps read LLMessenger" switch and the text that goes with it.
// Turning it on is a two-step action: the switch shows on, an inline confirmation says what
// it means, and nothing is stored until the user confirms. Turning it off needs no
// confirmation.

import Foundation

@MainActor
final class MCPAccessModel: ObservableObject {
    enum Phase: Equatable {
        case off
        case confirming
        case on
    }

    @Published private(set) var phase: Phase

    private let repo: SettingsRepository

    init(repo: SettingsRepository = SettingsRepository()) {
        self.repo = repo
        phase = repo.loadMCPServerEnabled() ? .on : .off
    }

    /// The switch reads on while the confirmation is showing, so it doesn't jump back.
    var switchIsOn: Bool { phase != .off }

    func setSwitch(_ on: Bool) {
        switch (on, phase) {
        case (true, .off):
            phase = .confirming
        case (false, .confirming):
            phase = .off
        case (false, .on):
            repo.saveMCPServerEnabled(false)
            phase = .off
        default:
            break
        }
    }

    func confirmEnable() {
        guard phase == .confirming else { return }
        repo.saveMCPServerEnabled(true)
        phase = .on
    }

    func cancelEnable() {
        guard phase == .confirming else { return }
        phase = .off
    }
}

enum MCPCopy {
    static let summary =
        "Claude Desktop, Claude Code, Cursor and other MCP apps can read your messages through this Mac. Off unless you turn it on."

    /// Shown before the switch is allowed to turn on.
    static let confirmationTitle = "Before you turn this on"
    static let confirmationPoints = [
        "A connected AI app can read your owed replies, digests, conversations and message search.",
        "It may pass what it reads to a cloud AI model. LLMessenger can't see or control that.",
        "Local-only conversations stay hidden from it, and are left out of new digests while this is on.",
        "It can only suggest replies. Each one waits in Act until you approve it."
    ]

    static let howItWorks = [
        "Apps connect through a helper that runs on this Mac. It opens no network port.",
        "A reply an app suggests appears in Act tagged External agent, meaning it came from a connected app, not from you. Nothing is sent until you approve it."
    ]

    static let localOnlyBlocksReads =
        "Local-only mode is on, so connected apps can't read anything right now."

    static let movedAppNote =
        "The path above is where LLMessenger is installed right now. If you move or reinstall the app, copy it again."
}

/// Snippets for connecting an MCP client to this app.
enum MCPSetup {
    static let serverName = "llmessenger"

    /// Pretty-printed JSON for the `mcpServers` section of a client's config file.
    static func configJSON(executablePath: String) -> String {
        let object: [String: Any] = [
            "mcpServers": [serverName: ["command": executablePath, "args": ["--mcp"]]]
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// The Terminal command that registers this app with Claude Code for the current user.
    /// The path is single-quoted so a space or quote in it can't change what the shell runs.
    static func claudeCodeCommand(executablePath: String) -> String {
        "claude mcp add --scope user \(serverName) -- \(shellQuoted(executablePath)) --mcp"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
