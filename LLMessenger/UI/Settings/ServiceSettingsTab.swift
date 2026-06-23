// LLMessenger/UI/Settings/ServiceSettingsTab.swift
import SwiftUI

private let kAllServices = ["imessage", "signal", "telegram", "slack"]

struct ServiceSettingsTab: View {
    @State private var configs: [ServiceConfig] = kAllServices.map { ServiceConfig.default(for: $0) }
    @State private var signalAccount: String = ""
    @State private var telegramApiId: String = ""
    @State private var telegramApiHash: String = ""
    @State private var saveStatus: SaveStatus = .idle
    @State private var healthByService: [String: ServiceHealth] = [:]
    @State private var isBuildingSummaries = false
    @State private var isSyncingContacts = false
    @State private var maintenanceStatus: String? = nil
    private let repo: SettingsRepository
    private let onBuild7DaySummaries: (() async -> Void)?
    private let onSyncContacts: (() async -> Void)?
    private let onRetryService: ((String) async -> Void)?

    enum SaveStatus: Equatable {
        case idle, saved
        case error(String)
    }

    init(database: AppDatabase? = nil,
         onBuild7DaySummaries: (() async -> Void)? = nil,
         onSyncContacts: (() async -> Void)? = nil,
         onRetryService: ((String) async -> Void)? = nil) {
        repo = SettingsRepository(database: database)
        self.onBuild7DaySummaries = onBuild7DaySummaries
        self.onSyncContacts = onSyncContacts
        self.onRetryService = onRetryService
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($configs, id: \.service) { $cfg in
                        ServiceCard(
                            config: $cfg,
                            signalAccount: $signalAccount,
                            telegramApiId: $telegramApiId,
                            telegramApiHash: $telegramApiHash,
                            health: healthByService[cfg.service],
                            onRetry: onRetryService
                        )
                        Rule()
                    }
                    maintenanceSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Rule()

            // Footer: status + save
            HStack {
                switch saveStatus {
                case .saved:
                    statusLine("Saved", color: Theme.ok)
                case .error(let msg):
                    statusLine(msg, color: Theme.signal)
                case .idle:
                    EmptyView()
                }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(PaperButtonStyle(prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear { load() }
        // Refresh health + configs whenever a retry or background poll
        // updates the DB, so the cards repaint without the user toggling
        // away and back to this tab.
        .onReceive(NotificationCenter.default.publisher(for: .serviceHealthDidChange)) { _ in
            load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .serviceConfigDidChange)) { _ in
            load()
        }
    }

    private func load() {
        let dbConfigs = (try? repo.loadAllServiceConfigs()) ?? []
        let dbByService = Dictionary(uniqueKeysWithValues: dbConfigs.map { ($0.service, $0) })
        configs = kAllServices.map { dbByService[$0] ?? ServiceConfig.default(for: $0) }
        signalAccount = (try? repo.loadSignalAccount()) ?? ""
        let tg = repo.loadTelegramCredentials()
        telegramApiId = tg.apiId
        telegramApiHash = tg.apiHash
        healthByService = (try? repo.loadAllServiceHealth()) ?? [:]
    }

    private func save() {
        do {
            for cfg in configs { try repo.saveServiceConfig(cfg) }
            try repo.saveSignalAccount(signalAccount)
            try repo.saveTelegramCredentials(apiId: telegramApiId, apiHash: telegramApiHash)
            NotificationCenter.default.post(name: .serviceConfigDidChange, object: nil)
            saveStatus = .saved
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = .idle }
        } catch {
            saveStatus = .error(error.localizedDescription)
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            WireLabel("Data")

            HStack(spacing: 10) {
                Button {
                    Task { await runBuildSummaries() }
                } label: {
                    HStack(spacing: 6) {
                        if isBuildingSummaries {
                            ProgressView().controlSize(.small)
                        }
                        Text("Build 7-day summary")
                    }
                }
                .buttonStyle(PaperButtonStyle())
                .disabled(isBuildingSummaries || onBuild7DaySummaries == nil)

                Button {
                    Task { await runSyncContacts() }
                } label: {
                    HStack(spacing: 6) {
                        if isSyncingContacts {
                            ProgressView().controlSize(.small)
                        }
                        Text("Sync contacts")
                    }
                }
                .buttonStyle(PaperButtonStyle())
                .disabled(isSyncingContacts || onSyncContacts == nil)

                Spacer()
            }

            Text(maintenanceStatus ?? "Generates per-conversation context the AI uses to recall older threads. Contact sync refreshes the @ mention picker.")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runBuildSummaries() async {
        guard let action = onBuild7DaySummaries else { return }
        isBuildingSummaries = true
        maintenanceStatus = "Building 7-day summary — this may take a minute…"
        await action()
        isBuildingSummaries = false
        maintenanceStatus = "7-day summary built. New digests will recall this context."
    }

    private func runSyncContacts() async {
        guard let action = onSyncContacts else { return }
        isSyncingContacts = true
        maintenanceStatus = "Syncing contacts…"
        await action()
        isSyncingContacts = false
        maintenanceStatus = "Contacts synced."
    }
}

// MARK: - Service Card

private struct ServiceCard: View {
    @Binding var config: ServiceConfig
    @Binding var signalAccount: String
    @Binding var telegramApiId: String
    @Binding var telegramApiHash: String
    var health: ServiceHealth?
    var onRetry: ((String) async -> Void)? = nil

    @State private var showingTelegramSignIn = false
    @State private var telegramSignInAdapter: SubprocessAdapter? = nil
    @State private var telegramSignInError: String? = nil
    @State private var showingSlackWorkspaces = false
    @State private var slackWorkspaceCount: Int = SlackWorkspaceStore.load().count
    @State private var isRetrying = false

    private var service: String { config.service }

    @State private var showAdvanced = false

    /// Four explicit states. Each state below renders ONE coherent card variant —
    /// never the same visual treatment repeated. This is the single source of truth
    /// for everything the card displays.
    enum CardState {
        case disabled                  // user toggled service off
        case notConfigured             // no credentials, prompt setup
        case broken(reason: String)    // credentials present but service not working
        case working                   // credentials + recent ok poll
    }

    var state: CardState {
        if !config.enabled { return .disabled }
        if !hasRequiredCredentials { return .notConfigured }
        if let health, health.status == "error" {
            return .broken(reason: health.lastError ?? "Connection error")
        }
        if let health, health.status == "warning" {
            return .broken(reason: health.lastError ?? "Connection warning")
        }
        if let health, health.status == "ok", !isHealthStale { return .working }
        // Credentials look complete but no fresh successful poll yet.
        return .broken(reason: health == nil ? "Pending first poll…" : "Last poll \(staleMinutes) min ago")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            marginRule
                .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 0) {
                switch state {
                case .disabled:        disabledBody
                case .notConfigured:   notConfiguredBody
                case .broken(let r):   brokenBody(reason: r)
                case .working:         workingBody
                }
            }
        }
        .padding(.vertical, 14)
        .animation(.easeInOut(duration: 0.15), value: config.enabled)
    }

    /// A 2pt margin rule down the left edge — the galley-proof redline. Only a
    /// service that needs attention gets colour: vermilion for errors, amber for
    /// warnings and stale polls. Healthy and idle entries stay unmarked.
    @ViewBuilder private var marginRule: some View {
        Group {
            switch state {
            case .broken:
                health?.status == "error" ? Theme.signal : Theme.standby
            case .working, .notConfigured, .disabled:
                Color.clear
            }
        }
        .frame(width: 2)
        .clipShape(RoundedRectangle(cornerRadius: 1))
    }

    /// Status dot matching the chrome bar's service health chips:
    /// sage = connected, amber = warning, vermilion = error, faint = idle.
    private var statusDot: some View {
        Circle()
            .fill(statusDotColor)
            .frame(width: 6, height: 6)
    }

    private var statusDotColor: Color {
        switch state {
        case .working:
            return Theme.ok
        case .broken:
            return health?.status == "error" ? Theme.signal : Theme.standby
        case .notConfigured, .disabled:
            return Theme.textTertiary.opacity(0.4)
        }
    }

    // MARK: - State: disabled

    private var disabledBody: some View {
        HStack(spacing: 10) {
            statusDot
            ServiceStamp(service: service, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(Theme.sans(13.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Off — not polling")
                    .font(Theme.sans(11)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $config.enabled)
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .accessibilityLabel("Enable \(displayName)")
                .tint(Theme.ok)
        }
        .opacity(0.7)
    }

    // MARK: - State: notConfigured

    private var notConfiguredBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statusDot
                ServiceStamp(service: service, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(Theme.sans(13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Not connected")
                        .font(Theme.sans(11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            Text(setupBlurb)
                .font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            primarySetupAction
        }
    }

    // MARK: - State: broken

    private func brokenBody(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statusDot
                ServiceStamp(service: service, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(Theme.sans(13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(reason)
                        .font(Theme.sans(11))
                        .foregroundStyle(health?.status == "error" ? Theme.signal : Theme.standby)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $config.enabled)
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .accessibilityLabel("Enable \(displayName)")
                    .tint(Theme.ok)
            }
            Rule()
            brokenBodyContent(reason: reason)
        }
    }

    /// Per-service fix UI shown below the broken-state header. Every variant has at
    /// least one actionable button so the user is never stuck staring at an error
    /// they can't address from this screen.
    @ViewBuilder
    private func brokenBodyContent(reason: String) -> some View {
        switch service {
        case "imessage":
            VStack(alignment: .leading, spacing: 10) {
                Text("macOS needs to allow LLMessenger to read your Messages database. Grant Full Disk Access, then tap Retry now.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Grant Full Disk Access") {
                        openFullDiskAccessSettings()
                    }
                    .buttonStyle(PaperButtonStyle(prominent: true))
                    retryButton
                }
            }
        case "signal":
            VStack(alignment: .leading, spacing: 10) {
                Text("Phone number is set but the local signal-mcp watch daemon isn't responding. Start it in a terminal (`signal-mcp watch`) or use Restart, then Retry now.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    WireLabel("Phone")
                        .frame(width: 70, alignment: .leading)
                    TextField("+1234567890", text: $signalAccount)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(13))
                }
                HStack(spacing: 8) {
                    retryButton
                    Link("signal-mcp setup →",
                         destination: URL(string: "https://github.com/googlarz/signal-mcp")!)
                        .font(Theme.sans(11))
                        .tint(Theme.textSecondary)
                    Spacer()
                }
            }
        case "telegram":
            VStack(alignment: .leading, spacing: 10) {
                Text(sessionFileExists
                     ? "Telegram session exists. Try Retry now — your existing session should reconnect without signing in again."
                     : "Telegram session is missing. Sign in to reconnect.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if sessionFileExists {
                        // Session is fine — Retry leads, re-sign-in is the escape hatch.
                        retryButton
                        Button("Re-sign in") { startTelegramSignIn() }
                            .buttonStyle(PaperButtonStyle())
                            .disabled(telegramApiId.isEmpty || telegramApiHash.isEmpty)
                    } else {
                        // No session — sign-in is the primary action.
                        Button("Sign in") { startTelegramSignIn() }
                            .buttonStyle(PaperButtonStyle(prominent: true))
                            .disabled(telegramApiId.isEmpty || telegramApiHash.isEmpty)
                        retryButton
                    }
                }
                if let err = telegramSignInError {
                    Text(err).font(Theme.sans(11)).foregroundStyle(Theme.signal)
                }
            }
            .sheet(isPresented: $showingTelegramSignIn, onDismiss: {
                telegramSignInAdapter?.stop()
                telegramSignInAdapter = nil
            }) {
                if let adapter = telegramSignInAdapter {
                    TelegramSignInView(adapter: adapter) {
                        NotificationCenter.default.post(name: .serviceConfigDidChange, object: nil)
                    }
                } else {
                    ProgressView("Starting adapter…").padding(40)
                }
            }
        case "slack":
            VStack(alignment: .leading, spacing: 10) {
                Text("A Slack workspace token failed to authenticate. Manage workspaces to re-add it, or Retry if it's a transient API hiccup.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Manage workspaces") { showingSlackWorkspaces = true }
                        .buttonStyle(PaperButtonStyle(prominent: true))
                    retryButton
                }
            }
            .sheet(isPresented: $showingSlackWorkspaces, onDismiss: {
                slackWorkspaceCount = SlackWorkspaceStore.load().count
                NotificationCenter.default.post(name: .serviceConfigDidChange, object: nil)
            }) {
                SlackWorkspacesView()
            }
        default:
            EmptyView()
        }
    }

    /// "Retry now" trigger that calls back into AppDelegate → pollEngine.pollNow.
    /// Hidden when no callback was provided (e.g. previews/tests).
    @ViewBuilder
    private var retryButton: some View {
        if onRetry != nil {
            Button {
                Task {
                    isRetrying = true
                    await onRetry?(service)
                    isRetrying = false
                }
            } label: {
                HStack(spacing: 4) {
                    if isRetrying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Retry now")
                }
            }
            .buttonStyle(PaperButtonStyle())
            .disabled(isRetrying)
        }
    }

    // MARK: - State: working

    private var workingBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statusDot
                ServiceStamp(service: service, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(Theme.sans(13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(workingIdentity)
                        .font(Theme.sans(11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Toggle("", isOn: $config.enabled)
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .accessibilityLabel("Enable \(displayName)")
                    .tint(Theme.ok)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                advancedBody
                    .padding(.top, 8)
            } label: {
                Text("Advanced")
                    .font(Theme.sans(11)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// Compact identity line shown under the service name in the working state.
    private var workingIdentity: String {
        let interval = intervalLabel(config.pollIntervalSeconds)
        switch service {
        case "imessage": return "Reading ~/Library/Messages — every \(interval)"
        case "signal":   return "\(signalAccount) — every \(interval)"
        case "telegram": return "Signed in — every \(interval)"
        case "slack":
            let plural = slackWorkspaceCount == 1 ? "" : "s"
            return "\(slackWorkspaceCount) workspace\(plural) — every \(interval)"
        default: return "Connected — every \(interval)"
        }
    }

    private func intervalLabel(_ seconds: Int) -> String {
        switch seconds {
        case 300:  return "5 min"
        case 900:  return "15 min"
        case 1800: return "30 min"
        case 3600: return "1 hour"
        case 7200: return "2 hours"
        default:
            let mins = seconds / 60
            return mins == 1 ? "1 min" : "\(mins) min"
        }
    }

    /// Things you rarely change — collapsed behind a disclosure so the card is calm.
    @ViewBuilder
    private var advancedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Poll every")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textSecondary)
                Picker("", selection: $config.pollIntervalSeconds) {
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("30 min").tag(1800)
                    Text("1 hour").tag(3600)
                    Text("2 hours").tag(7200)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 250)
            }
            switch service {
            case "signal":
                HStack {
                    WireLabel("Phone")
                        .frame(width: 70, alignment: .leading)
                    TextField("+1234567890", text: $signalAccount)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(13))
                }
            case "telegram":
                HStack {
                    WireLabel("API ID")
                        .frame(width: 70, alignment: .leading)
                    TextField("", text: $telegramApiId)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(13))
                }
                HStack {
                    WireLabel("API Hash")
                        .frame(width: 70, alignment: .leading)
                    SecureField("", text: $telegramApiHash)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(13))
                }
            case "slack":
                Button("Manage workspaces…") { showingSlackWorkspaces = true }
                    .buttonStyle(PaperButtonStyle())
                    .sheet(isPresented: $showingSlackWorkspaces, onDismiss: {
                        slackWorkspaceCount = SlackWorkspaceStore.load().count
                        NotificationCenter.default.post(name: .serviceConfigDidChange, object: nil)
                    }) {
                        SlackWorkspacesView()
                    }
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Shared building blocks

    private var setupBlurb: String {
        switch service {
        case "imessage": return "Summarise your iMessage conversations. Requires Full Disk Access."
        case "signal":   return "Summarise your Signal conversations. Requires the signal-mcp daemon and your phone number."
        case "telegram": return "Summarise your Telegram conversations. Requires API credentials from my.telegram.org and a one-time sign-in."
        case "slack":    return "Summarise messages across one or more Slack workspaces. You'll paste an OAuth token from a private Slack app you create."
        default:         return ""
        }
    }

    @ViewBuilder
    private var primarySetupAction: some View {
        switch service {
        case "imessage":
            Button("Grant Full Disk Access") {
                openFullDiskAccessSettings()
            }
            .buttonStyle(PaperButtonStyle(prominent: true))
        case "signal":
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    WireLabel("Phone")
                        .frame(width: 70, alignment: .leading)
                    TextField("+1234567890", text: $signalAccount)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(13))
                }
                Text("Then start the signal-mcp watch daemon to begin polling.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.textTertiary)
            }
        case "telegram":
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    WireLabel("API ID")
                        .frame(width: 70, alignment: .leading)
                    TextField("", text: $telegramApiId)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(13))
                }
                HStack {
                    WireLabel("API Hash")
                        .frame(width: 70, alignment: .leading)
                    SecureField("", text: $telegramApiHash)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(13))
                }
                HStack {
                    Link("Get credentials at my.telegram.org →",
                         destination: URL(string: "https://my.telegram.org")!)
                        .font(Theme.sans(11))
                        .tint(Theme.textSecondary)
                    Spacer()
                    if !telegramApiId.isEmpty && !telegramApiHash.isEmpty {
                        Button("Connect Telegram") { startTelegramSignIn() }
                            .buttonStyle(PaperButtonStyle(prominent: true))
                    }
                }
            }
            .sheet(isPresented: $showingTelegramSignIn, onDismiss: {
                telegramSignInAdapter?.stop()
                telegramSignInAdapter = nil
            }) {
                if let adapter = telegramSignInAdapter {
                    TelegramSignInView(adapter: adapter) {
                        NotificationCenter.default.post(name: .serviceConfigDidChange, object: nil)
                    }
                } else {
                    ProgressView("Starting adapter…").padding(40)
                }
            }
        case "slack":
            Button("Add a workspace") {
                showingSlackWorkspaces = true
            }
            .buttonStyle(PaperButtonStyle(prominent: true))
            .sheet(isPresented: $showingSlackWorkspaces, onDismiss: {
                slackWorkspaceCount = SlackWorkspaceStore.load().count
                NotificationCenter.default.post(name: .serviceConfigDidChange, object: nil)
            }) {
                SlackWorkspacesView()
            }
        default:
            EmptyView()
        }
    }

    // MARK: Metadata

    private var displayName: String {
        switch service {
        case "imessage": return "iMessage"
        case "signal":   return "Signal"
        case "telegram": return "Telegram"
        case "slack":    return "Slack"
        default:         return service.capitalized
        }
    }

    /// A health record is "stale" if its lastCheck is older than 2× the configured poll
    /// interval. A successful poll from yesterday shouldn't keep claiming green today.
    private var isHealthStale: Bool {
        guard let lastCheck = health?.lastCheck else { return true }
        let staleAfter = TimeInterval(max(config.pollIntervalSeconds * 2, 600))
        return Date().timeIntervalSince(lastCheck) > staleAfter
    }

    private var staleMinutes: Int {
        guard let lastCheck = health?.lastCheck else { return 0 }
        return max(0, Int(Date().timeIntervalSince(lastCheck) / 60))
    }

    /// True when the per-service credential criteria are satisfied. A working state still
    /// requires a recent successful poll on top of this — credentials present alone is not enough.
    private var hasRequiredCredentials: Bool {
        switch service {
        case "imessage":
            // Best signal we have without a real probe: the chat.db file is readable.
            // Full Disk Access may still block a real query — surfaced via the health record.
            let path = NSHomeDirectory() + "/Library/Messages/chat.db"
            return FileManager.default.isReadableFile(atPath: path)
        case "signal":
            return !signalAccount.trimmingCharacters(in: .whitespaces).isEmpty
        case "telegram":
            return !telegramApiId.trimmingCharacters(in: .whitespaces).isEmpty
                && !telegramApiHash.trimmingCharacters(in: .whitespaces).isEmpty
                && sessionFileExists
        case "slack":
            return slackWorkspaceCount > 0
        default:
            return false
        }
    }

    private var sessionFileExists: Bool {
        FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/.config/llmessenger/data/telegram/session.session"
        )
    }

    /// Surfaces FDA setup instructions to the user. The programmatic deep-link
    /// trigger ("Open System Settings now") is offered as a button, but the
    /// manual steps lead — because on some Macs the URL-scheme dispatch fires
    /// a "System Settings is not open anymore" popup that we can't suppress.
    /// Showing instructions first means the user always has a working path
    /// even when macOS' programmatic open silently fails.
    private func openFullDiskAccessSettings() {
        showManualFDAInstructions()
    }

    private func showManualFDAInstructions() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Grant Full Disk Access to LLMessenger"
        alert.informativeText = """
        macOS needs you to add LLMessenger to Full Disk Access before it can read your iMessage history.

        Manual steps (works on every Mac):
          1. Apple menu  →  System Settings…
          2. Privacy & Security  →  Full Disk Access
          3. Click the +
          4. Choose LLMessenger.app
          5. Quit and reopen LLMessenger

        The buttons below can speed it up but don't always work — some Macs immediately quit System Settings on URL hand-off ("is not open anymore"). If that happens, just use the Apple menu manually.
        """
        alert.addButton(withTitle: "Open System Settings")       // rightmost (default)
        alert.addButton(withTitle: "Reveal LLMessenger.app")     // middle
        alert.addButton(withTitle: "Cancel")                      // leftmost

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            tryLaunchSystemSettings()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default:
            break
        }
    }

    /// Open System Settings deep-linked to Full Disk Access. Uses the
    /// canonical URL scheme that drives the OS-level handoff; falls back to a
    /// plain System Settings launch if the URL hand-off doesn't open anything.
    private func tryLaunchSystemSettings() {
        let fdaURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        if NSWorkspace.shared.open(fdaURL) { return }

        // Fallback: launch System Settings with no deep-link. User navigates
        // to Privacy & Security → Full Disk Access manually (the 5 steps are
        // in the alert above this button).
        let appURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config,
                                          completionHandler: nil)
    }

    private func startTelegramSignIn() {
        telegramSignInError = nil
        // Resolve adapter binary path (mirrors AppDelegate.telegramAdapterPath).
        var binaryPath: String? = Bundle.main.path(forResource: "telegram-adapter", ofType: nil)
        let communityPath = NSHomeDirectory() + "/.config/llmessenger/adapters/telegram/telegram-adapter"
        if binaryPath == nil && FileManager.default.fileExists(atPath: communityPath) {
            binaryPath = communityPath
        }
        guard let path = binaryPath else {
            telegramSignInError = "Telegram adapter binary not found."
            return
        }
        let sessionPath = NSHomeDirectory() + "/.config/llmessenger/data/telegram/session"
        let adapterConfig: [String: Any] = [
            "api_id":       telegramApiId,
            "api_hash":     telegramApiHash,
            "session_path": sessionPath
        ]
        let adapter = SubprocessAdapter(serviceID: "telegram-auth", adapterPath: path, config: adapterConfig)
        Task { @MainActor in
            do {
                try await adapter.start()
                telegramSignInAdapter = adapter
                showingTelegramSignIn = true
            } catch {
                telegramSignInError = "Failed to start adapter: \(error.localizedDescription)"
            }
        }
    }
}
