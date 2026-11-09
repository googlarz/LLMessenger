import SwiftUI

struct PrivacySettingsTab: View {
    @State private var localOnlyMode: Bool
    @State private var sanitizeBeforeSend: Bool
    @State private var updateChecksEnabled: Bool
    @StateObject private var mcp: MCPAccessModel
    @State private var copiedLabel: String? = nil
    @ObservedObject private var auditLog = NetworkAuditLog.shared
    private let repo: SettingsRepository
    private let executablePath: String
    private let lastAgentRequest: () -> (date: Date, tool: String)?
    @State private var showMCPSetup: Bool

    /// `repo` and `executablePath` are injectable so previews and snapshots don't touch the
    /// user's real settings or show a machine-specific path.
    init(repo: SettingsRepository = SettingsRepository(),
         mcp: MCPAccessModel? = nil,
         executablePath: String? = nil,
         lastAgentRequest: @escaping () -> (date: Date, tool: String)? = { MCPActivityLog().load() }) {
        self.repo = repo
        self.lastAgentRequest = lastAgentRequest
        // Setup steps matter until an app has connected once; after that they are reference.
        _showMCPSetup = State(initialValue: lastAgentRequest() == nil)
        self.executablePath = executablePath ?? Bundle.main.executablePath ?? "LLMessenger"
        _localOnlyMode = State(initialValue: repo.loadLocalOnlyMode())
        _sanitizeBeforeSend = State(initialValue: repo.loadSanitizeBeforeSend())
        _updateChecksEnabled = State(initialValue: repo.loadUpdateChecksEnabled())
        _mcp = StateObject(wrappedValue: mcp ?? MCPAccessModel(repo: repo))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                modesSection
                Rule()
                mcpSection
                Rule()
                updatesSection
                Rule()
                dataFlowSection
                Rule()
                networkLogSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Modes

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            WireLabel("Privacy")

            SettingsToggleRow(title: "Local-only mode", caption: "Forces Ollama as the LLM, stops cloud-only services such as Slack, and blocks AI apps connected over MCP from reading anything. A request already under way may finish; nothing new is sent.", isOn: $localOnlyMode)
            .onChange(of: localOnlyMode) { _, enabled in
                repo.saveLocalOnlyMode(enabled)
                NotificationCenter.default.post(name: .privacyModeDidChange, object: nil)
                NotificationCenter.default.post(name: .llmProviderDidChange, object: nil)
            }

            Rule()

            SettingsToggleRow(title: "Redact sensitive patterns before sending to cloud LLM", caption: "Replaces credit card numbers, US SSNs, IBANs, and email addresses with [REDACTED:…] tokens in cloud LLM prompts. Best-effort, not a guarantee. May reduce digest quality.", isOn: $sanitizeBeforeSend)
            .onChange(of: sanitizeBeforeSend) { _, enabled in
                repo.saveSanitizeBeforeSend(enabled)
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: - MCP

    private var mcpClientConfig: String { MCPSetup.configJSON(executablePath: executablePath) }
    private var claudeCodeCommand: String { MCPSetup.claudeCodeCommand(executablePath: executablePath) }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            WireLabel("AI Apps (MCP)")

            SettingsToggleRow(title: "Let AI apps read LLMessenger", caption: MCPCopy.summary, isOn: Binding(get: { mcp.switchIsOn }, set: { mcp.setSwitch($0) }))

            if mcp.phase == .confirming {
                mcpConfirmation
            }

            if localOnlyMode && mcp.phase == .on {
                Text(MCPCopy.localOnlyBlocksReads)
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.standby)
                    .fixedSize(horizontal: false, vertical: true)
            }

            mcpStatusSlot

            if mcp.phase == .on {
                mcpHowItWorks
                mcpSetup
            }
        }
        .padding(.vertical, 14)
    }

    /// Proof that the switch does something: when a connected app last asked for data.
    @ViewBuilder private var mcpStatusSlot: some View {
        if mcp.phase == .on {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(MCPStatusLine.text(lastAgentRequest(), now: context.date))
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mcpConfirmation: some View {
        HStack(alignment: .top, spacing: 0) {
            Theme.standby
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 8) {
                Text(MCPCopy.confirmationTitle)
                    .font(Theme.sans(12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                ForEach(MCPCopy.confirmationPoints, id: \.self) { point in
                    bullet(point)
                }
                Text("The switch stays off until you confirm.")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                HStack(spacing: 8) {
                    Button("Turn On") { mcp.confirmEnable() }
                        .buttonStyle(PaperButtonStyle(prominent: true))
                    Button("Cancel") { mcp.cancelEnable() }
                        .buttonStyle(PaperButtonStyle())
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private var mcpHowItWorks: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MCPCopy.howItWorks, id: \.self) { line in
                bullet(line)
            }
        }
        .padding(.top, 4)
    }

    private var mcpSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rule()
            DisclosureGroup(isExpanded: $showMCPSetup) {
                mcpSetupSteps.padding(.top, 10)
            } label: {
                WireLabel("Connect an app")
            }
        }
        .padding(.top, 6)
    }

    private var mcpSetupSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            setupBlock(title: "Claude Desktop", steps: [
                "Open Claude, then Settings, Developer, Edit Config.",
                "Paste the config below into the file. If it already has \u{201C}mcpServers\u{201D}, add only the llmessenger entry.",
                "Quit and reopen Claude."
            ])
            setupBlock(title: "Claude Code", steps: [
                "Copy the command below and run it in Terminal.",
                "Start a new Claude Code session."
            ])
            setupBlock(title: "Cursor", steps: [
                "Paste the config below into ~/.cursor/mcp.json.",
                "Restart Cursor."
            ])

            snippet(label: "Config", text: mcpClientConfig, copyTitle: "Copy config")
            snippet(label: "Claude Code command", text: claudeCodeCommand, copyTitle: "Copy command")

            Text(MCPCopy.movedAppNote)
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setupBlock(title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Theme.sans(12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, alignment: .trailing)
                    Text(step)
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func snippet(label: String, text: String, copyTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                WireLabel(label)
                Spacer()
                Button(copiedLabel == label ? "Copied" : copyTitle) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copiedLabel = label
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedLabel == label { copiedLabel = nil }
                    }
                }
                .buttonStyle(WireActionStyle())
            }
            Text(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .strokeBorder(Theme.border, lineWidth: Theme.hairline)
                )
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            WireLabel("Updates")

            SettingsToggleRow(title: "Check GitHub for new versions once a day", caption: "When LLMessenger starts, it asks GitHub for the latest release, at most once a day. The request carries no message content or account details; GitHub sees your IP address and the app and macOS versions, as with any web request. Updates are never installed for you.", isOn: $updateChecksEnabled)
            .onChange(of: updateChecksEnabled) { _, enabled in
                repo.saveUpdateChecksEnabled(enabled)
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: - Data flow

    private var dataFlowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WireLabel("Data Flow")

            bullet("Your messages are stored locally at ~/Library/Application Support/LLMessenger/.")
            bullet("There is no LLMessenger server. The developer cannot see your data.")
            bullet(PrivacyCopy.cloudEgress)
            bullet("API keys and Slack tokens are stored in the macOS Keychain, never in plain files.")
            bullet(PrivacyCopy.noTelemetry)

            Link("Read the full privacy & data-flow document →",
                 destination: URL(string: "https://github.com/googlarz/LLMessenger/blob/main/PRIVACY.md")!)
                .font(Theme.sans(11, weight: .medium))
                .tint(Theme.textSecondary)
                .padding(.top, 4)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Live network log

    private var networkLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WireLabel("Network Log — This Session")
                Spacer()
                Button("Clear") { auditLog.clear() }
                    .buttonStyle(WireActionStyle())
                    .disabled(auditLog.entries.isEmpty)
            }

            if auditLog.entries.isEmpty {
                Text("No outbound requests recorded yet. The app records every cloud HTTPS call here — only metadata (provider, endpoint, status, byte count), never message content.")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(auditLog.entries.reversed()) { entry in
                        AuditRow(entry: entry)
                        if entry.id != auditLog.entries.reversed().last?.id {
                            Rule()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 14)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

/// The two Data Flow claims that must stay exactly true; PRIVACY.md and the README say the same.
enum PrivacyCopy {
    static let cloudEgress =
        "Cloud egress only happens when you set up Anthropic, OpenAI or Slack, or when an AI app connected over MCP reads your messages and passes them on."
    static let noTelemetry =
        "No analytics or telemetry, and nothing is sent to the developer. The only thing LLMessenger looks up on its own is a new version on GitHub, at most once a day; you can turn that off under Updates."
}

private struct AuditRow: View {
    let entry: NetworkAuditLog.Entry
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 60, alignment: .leading)
            Text(entry.provider)
                .font(Theme.sans(11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 90, alignment: .leading)
            Text("\(entry.method) \(entry.endpoint)")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(rightLabel)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        if entry.isLocal { return Theme.textTertiary }
        if let s = entry.status, s < 400 { return Theme.ok }
        if entry.status != nil { return Theme.standby }
        return Theme.signal
    }

    private var rightLabel: String {
        var parts: [String] = []
        if let s = entry.status { parts.append("\(s)") }
        if entry.requestBytes > 0 { parts.append("\(entry.requestBytes) B") }
        if let ms = entry.durationMs { parts.append("\(ms) ms") }
        if entry.error != nil { parts.append("error") }
        return parts.joined(separator: " · ")
    }
}

enum MCPStatusLine {
    /// Only the time and the kind of request are known — never what was asked for.
    static func text(_ last: (date: Date, tool: String)?, now: Date) -> String {
        guard let last else { return "No app has asked for anything yet." }
        let seconds = max(0, now.timeIntervalSince(last.date))
        let when: String
        if seconds < 60 {
            when = "just now"
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            when = formatter.localizedString(for: last.date, relativeTo: now)
        }
        return "Last request from a connected app: \(when) (\(describe(last.tool)))."
    }

    static func describe(_ tool: String) -> String {
        switch tool {
        case "get_owed_replies": return "who is waiting on you"
        case "get_latest_digest": return "your latest digest"
        case "search_messages": return "a message search"
        case "list_conversations": return "your conversation list"
        case "get_conversation_messages": return "messages from one conversation"
        case "propose_reply": return "a suggested reply"
        default: return "a request"
        }
    }
}
