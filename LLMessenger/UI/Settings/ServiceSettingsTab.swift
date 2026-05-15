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
                VStack(spacing: 10) {
                    ForEach($configs, id: \.service) { $cfg in
                        ServiceCard(
                            config: $cfg,
                            signalAccount: $signalAccount,
                            telegramApiId: $telegramApiId,
                            telegramApiHash: $telegramApiHash,
                            health: healthByService[cfg.service],
                            onRetry: onRetryService
                        )
                    }
                    maintenanceSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            // Footer: status + save
            HStack {
                Group {
                    switch saveStatus {
                    case .saved:
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .error(let msg):
                        Label(msg, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    case .idle:
                        EmptyView()
                    }
                }
                .font(.subheadline)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
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

    @ViewBuilder
    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 10) {
                Button {
                    Task { await runBuildSummaries() }
                } label: {
                    HStack(spacing: 6) {
                        if isBuildingSummaries {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        Text("Build 7-day summary")
                    }
                }
                .disabled(isBuildingSummaries || onBuild7DaySummaries == nil)

                Button {
                    Task { await runSyncContacts() }
                } label: {
                    HStack(spacing: 6) {
                        if isSyncingContacts {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "person.2.arrow.trianglehead.counterclockwise")
                        }
                        Text("Sync contacts")
                    }
                }
                .disabled(isSyncingContacts || onSyncContacts == nil)

                Spacer()
            }

            Text(maintenanceStatus ?? "Generates per-conversation context the AI uses to recall older threads. Contact sync refreshes the @ mention picker.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func runBuildSummaries() async {
        guard let action = onBuild7DaySummaries else { return }
        isBuildingSummaries = true
        maintenanceStatus = "Building 7-day summary — this may take a minute…"
        await action()
        isBuildingSummaries = false
        maintenanceStatus = "7-day summary built. New briefs will recall this context."
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
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .disabled:        disabledBody
            case .notConfigured:   notConfiguredBody
            case .broken(let r):   brokenBody(reason: r)
            case .working:         workingBody
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(accentStripe, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.15), value: config.enabled)
    }

    /// A 3pt accent stripe down the left edge so each state is identifiable from a
    /// peripheral glance: green = working, orange = needs attention, transparent otherwise.
    @ViewBuilder private var accentStripe: some View {
        switch state {
        case .working:
            Rectangle().fill(Color.green).frame(width: 3)
        case .broken:
            Rectangle().fill(Color.orange).frame(width: 3)
        case .notConfigured, .disabled:
            EmptyView()
        }
    }

    // MARK: - State: disabled

    private var disabledBody: some View {
        HStack(spacing: 12) {
            serviceIcon(tinted: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.headline).foregroundStyle(.secondary)
                Text("Off — not polling")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: $config.enabled)
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .tint(.green)
        }
        .padding(14)
        .opacity(0.7)
    }

    // MARK: - State: notConfigured

    private var notConfiguredBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                serviceIcon(tinted: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName).font(.headline)
                    Text("Not connected")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            Text(setupBlurb)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            primarySetupAction
        }
        .padding(14)
    }

    // MARK: - State: broken

    private func brokenBody(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                serviceIcon(tinted: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName).font(.headline)
                    Text(reason)
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $config.enabled)
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .tint(.green)
            }
            Divider()
            brokenBodyContent(reason: reason)
        }
        .padding(14)
    }

    /// Per-service fix UI shown below the broken-state header. Every variant has at
    /// least one actionable button so the user is never stuck staring at an error
    /// they can't address from this screen.
    @ViewBuilder
    private func brokenBodyContent(reason: String) -> some View {
        switch service {
        case "imessage":
            VStack(alignment: .leading, spacing: 10) {
                Text("macOS needs to allow LLMessenger to read your Messages database. Grant Full Disk Access, then quit and reopen the app.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        openFullDiskAccessSettings()
                    } label: {
                        Label("Grant Full Disk Access", systemImage: "lock.shield")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    retryButton
                }
            }
        case "signal":
            VStack(alignment: .leading, spacing: 10) {
                Text("Phone number is set but the local signal-mcp watch daemon isn't responding. Start it in a terminal (`signal-mcp watch`) or use Restart, then Retry now.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Phone")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    TextField("+1234567890", text: $signalAccount)
                        .textFieldStyle(.roundedBorder).font(.subheadline)
                }
                HStack(spacing: 8) {
                    retryButton
                    Link("signal-mcp setup →",
                         destination: URL(string: "https://github.com/googlarz/signal-mcp")!)
                        .font(.caption)
                    Spacer()
                }
            }
        case "telegram":
            VStack(alignment: .leading, spacing: 10) {
                Text(sessionFileExists
                     ? "Telegram session exists but the adapter isn't responding. Re-sign in or try Retry now."
                     : "Telegram session is missing. Sign in to reconnect.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Re-sign in") { startTelegramSignIn() }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                        .disabled(telegramApiId.isEmpty || telegramApiHash.isEmpty)
                    retryButton
                }
                if let err = telegramSignInError {
                    Text(err).font(.caption).foregroundStyle(.red)
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
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Manage workspaces") { showingSlackWorkspaces = true }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
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
            .controlSize(.regular)
            .disabled(isRetrying)
        }
    }

    // MARK: - State: working

    private var workingBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                serviceIcon(tinted: true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName).font(.headline)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    Text(workingIdentity)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $config.enabled)
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .tint(.green)
            }
            .padding(14)

            DisclosureGroup(isExpanded: $showAdvanced) {
                advancedBody
                    .padding(.top, 8)
            } label: {
                Text("Advanced")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    /// Compact identity line shown under the service name in the working state.
    private var workingIdentity: String {
        switch service {
        case "imessage": return "Reading ~/Library/Messages — every \(config.pollIntervalMinutes) min"
        case "signal":   return "\(signalAccount) — every \(config.pollIntervalMinutes) min"
        case "telegram": return "Signed in — every \(config.pollIntervalMinutes) min"
        case "slack":
            let plural = slackWorkspaceCount == 1 ? "" : "s"
            return "\(slackWorkspaceCount) workspace\(plural) — every \(config.pollIntervalMinutes) min"
        default: return "Connected — every \(config.pollIntervalMinutes) min"
        }
    }

    /// Things you rarely change — collapsed behind a disclosure so the card is calm.
    @ViewBuilder
    private var advancedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Poll interval").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Stepper("\(config.pollIntervalMinutes) min",
                        value: $config.pollIntervalMinutes,
                        in: 5...120, step: 5)
                    .fixedSize().controlSize(.small)
            }
            switch service {
            case "signal":
                HStack {
                    Text("Phone").font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    TextField("+1234567890", text: $signalAccount)
                        .textFieldStyle(.roundedBorder).font(.subheadline)
                }
            case "telegram":
                HStack {
                    Text("API ID").font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    TextField("", text: $telegramApiId)
                        .textFieldStyle(.roundedBorder).font(.subheadline)
                }
                HStack {
                    Text("API Hash").font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    SecureField("", text: $telegramApiHash)
                        .textFieldStyle(.roundedBorder).font(.subheadline)
                }
            case "slack":
                Button("Manage workspaces…") { showingSlackWorkspaces = true }
                    .controlSize(.small)
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

    private func serviceIcon(tinted: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(tinted ? iconBackground : Color(nsColor: .tertiaryLabelColor).opacity(0.35))
                .frame(width: 36, height: 36)
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tinted ? .white : Color(nsColor: .secondaryLabelColor))
        }
    }

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
            Button {
                openFullDiskAccessSettings()
            } label: {
                Label("Grant Full Disk Access", systemImage: "lock.shield")
            }
            .buttonStyle(.borderedProminent).controlSize(.regular)
        case "signal":
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Phone").font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    TextField("+1234567890", text: $signalAccount)
                        .textFieldStyle(.roundedBorder).font(.subheadline)
                }
                Text("Then start the signal-mcp watch daemon to begin polling.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        case "telegram":
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API ID").font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    TextField("", text: $telegramApiId)
                        .textFieldStyle(.roundedBorder).font(.subheadline)
                }
                HStack {
                    Text("API Hash").font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    SecureField("", text: $telegramApiHash)
                        .textFieldStyle(.roundedBorder).font(.subheadline)
                }
                HStack {
                    Link("Get credentials at my.telegram.org →",
                         destination: URL(string: "https://my.telegram.org")!)
                        .font(.caption)
                    Spacer()
                    if !telegramApiId.isEmpty && !telegramApiHash.isEmpty {
                        Button("Connect Telegram") { startTelegramSignIn() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
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
            Button {
                showingSlackWorkspaces = true
            } label: {
                Label("Add a workspace", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent).controlSize(.regular)
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

    private var icon: String {
        switch service {
        case "imessage": return "message.fill"
        case "signal":   return "lock.shield.fill"
        case "telegram": return "paperplane.fill"
        case "slack":    return "number"
        default:         return "antenna.radiowaves.left.and.right"
        }
    }

    private var iconBackground: Color {
        switch service {
        case "imessage": return Color(red: 0.20, green: 0.78, blue: 0.35)   // iMessage green
        case "signal":   return Color(red: 0.22, green: 0.53, blue: 0.95)   // Signal blue
        case "telegram": return Color(red: 0.20, green: 0.66, blue: 0.90)   // Telegram blue
        case "slack":    return Color(red: 0.55, green: 0.36, blue: 0.66)   // Slack aubergine
        default:         return .accentColor
        }
    }

    /// A health record is "stale" if its lastCheck is older than 2× the configured poll
    /// interval. A successful poll from yesterday shouldn't keep claiming green today.
    private var isHealthStale: Bool {
        guard let lastCheck = health?.lastCheck else { return true }
        let staleAfter = TimeInterval(max(config.pollIntervalMinutes * 2, 10) * 60)
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
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
            NSWorkspace.shared.open(url)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default:
            break
        }
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
