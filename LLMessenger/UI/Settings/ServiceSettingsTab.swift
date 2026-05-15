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

    enum SaveStatus: Equatable {
        case idle, saved
        case error(String)
    }

    init(database: AppDatabase? = nil,
         onBuild7DaySummaries: (() async -> Void)? = nil,
         onSyncContacts: (() async -> Void)? = nil) {
        repo = SettingsRepository(database: database)
        self.onBuild7DaySummaries = onBuild7DaySummaries
        self.onSyncContacts = onSyncContacts
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
                            health: healthByService[cfg.service]
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

    @State private var showingTelegramSignIn = false
    @State private var telegramSignInAdapter: SubprocessAdapter? = nil
    @State private var telegramSignInError: String? = nil
    @State private var showingSlackWorkspaces = false
    @State private var slackWorkspaceCount: Int = SlackWorkspaceStore.load().count

    private var service: String { config.service }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    // Icon background desaturates to a neutral grey when the service is
                    // not in a green state — otherwise a healthy iMessage green badge
                    // tricks the eye into "looks OK" even though FDA is missing.
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isStatusGreen ? iconBackground : Color(nsColor: .tertiaryLabelColor).opacity(0.45))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isStatusGreen ? .white : Color(nsColor: .secondaryLabelColor))

                    // Prominent status corner badge — visible at a glance even when the
                    // small dot in the subtitle row is missed. Hidden in the OK case to
                    // avoid clutter, since a healthy green icon already conveys status.
                    if !isStatusGreen {
                        Image(systemName: statusBadgeIcon)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(statusColor)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 3, y: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusLabel)
                            .font(.caption)
                            .foregroundStyle(statusColor == .red ? .red : Theme.textSecondary)
                    }
                }

                Spacer()

                // A red "Fix" pill next to the toggle when the service has missing
                // credentials or a hard error — makes it visually obvious that
                // enabled ≠ working. The toggle itself only carries the user's intent.
                if config.enabled, !isStatusGreen {
                    Text(toggleAdornmentLabel)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.18))
                        .foregroundStyle(statusColor == .red ? .red : .orange)
                        .clipShape(Capsule())
                }

                Toggle("", isOn: $config.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    // Grey-out the toggle when the user has nothing to do at this point
                    // (service is broken-but-on); avoids the "blue = good" misread.
                    .tint(isStatusGreen ? .accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .padding(14)

            // Credentials row (only when enabled)
            if config.enabled {
                Divider().padding(.horizontal, 14)
                credentialsSection
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Divider().padding(.horizontal, 14)
            }

            // Poll interval row
            if config.enabled {
                HStack {
                    Text("Poll interval")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Stepper(
                        "\(config.pollIntervalMinutes) min",
                        value: $config.pollIntervalMinutes,
                        in: 5...120, step: 5
                    )
                    .fixedSize()
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.15), value: config.enabled)
    }

    // MARK: Credentials

    @ViewBuilder
    private var credentialsSection: some View {
        if service == "imessage" {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                    Text("Requires Full Disk Access to read your Messages database.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Open Privacy & Security Settings →") {
                    openFullDiskAccessSettings()
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        } else if service == "signal" {
            HStack {
                Text("Phone number")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                TextField("+1234567890", text: $signalAccount)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
            }
        } else if service == "slack" {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Workspaces")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(slackWorkspaceCount == 0
                         ? "None — add at least one to start polling."
                         : "\(slackWorkspaceCount) workspace\(slackWorkspaceCount == 1 ? "" : "s") configured")
                        .font(.subheadline)
                    Spacer()
                    Button("Manage…") { showingSlackWorkspaces = true }
                        .controlSize(.small)
                }
                HStack {
                    Spacer()
                    Link("How to get a Slack token →",
                         destination: URL(string: "https://api.slack.com/apps")!)
                        .font(.caption)
                }
            }
            .sheet(isPresented: $showingSlackWorkspaces, onDismiss: {
                slackWorkspaceCount = SlackWorkspaceStore.load().count
                NotificationCenter.default.post(name: .serviceConfigDidChange, object: nil)
            }) {
                SlackWorkspacesView()
            }
        } else if service == "telegram" {
            VStack(spacing: 8) {
                HStack {
                    Text("API ID")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    TextField("", text: $telegramApiId)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                }
                HStack {
                    Text("API Hash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    SecureField("", text: $telegramApiHash)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                }
                HStack {
                    Spacer()
                    Link("Get credentials at my.telegram.org →",
                         destination: URL(string: "https://my.telegram.org")!)
                        .font(.caption)
                }
                if isConnected && !sessionFileExists {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Session not found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let err = telegramSignInError {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Button("Connect Telegram") {
                            startTelegramSignIn()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .sheet(isPresented: $showingTelegramSignIn, onDismiss: {
                        telegramSignInAdapter?.stop()
                        telegramSignInAdapter = nil
                    }) {
                        if let adapter = telegramSignInAdapter {
                            TelegramSignInView(adapter: adapter) {
                                NotificationCenter.default.post(
                                    name: .serviceConfigDidChange, object: nil)
                            }
                        } else {
                            ProgressView("Starting adapter…").padding(40)
                        }
                    }
                }
            }
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

    private var isConnected: Bool {
        switch service {
        case "imessage":
            // fileExists returns true even without Full Disk Access; try to open for reading
            // to distinguish "file present + FDA granted" from "file present, FDA missing".
            let path = NSHomeDirectory() + "/Library/Messages/chat.db"
            return FileManager.default.isReadableFile(atPath: path)
        case "signal":
            return !signalAccount.trimmingCharacters(in: .whitespaces).isEmpty
        case "telegram":
            return !telegramApiId.trimmingCharacters(in: .whitespaces).isEmpty
                && !telegramApiHash.trimmingCharacters(in: .whitespaces).isEmpty
        case "slack":
            return slackWorkspaceCount > 0
        default:
            return false
        }
    }

    /// Three-state model for the status dot:
    /// - .green only when a successful poll has been recorded recently AND credentials still satisfy
    ///   the per-service criteria (e.g. Slack still has ≥1 workspace).
    /// - .orange when credentials are present but the service hasn't been verified yet,
    ///   or when the last poll surfaced a warning, or when health is stale.
    /// - .red on a hard error.
    /// - .grey when credentials are missing (or the service is disabled).
    private var statusColor: Color {
        guard config.enabled else { return Color(nsColor: .tertiaryLabelColor) }
        if !hasRequiredCredentials { return Color(nsColor: .tertiaryLabelColor) }
        if let health, health.status == "error" { return .red }
        if let health, health.status == "warning" { return .orange }
        if let health, health.status == "ok", !isHealthStale { return .green }
        // Credentials look complete but PollEngine hasn't confirmed (or health is stale).
        return .orange
    }

    private var statusLabel: String {
        guard config.enabled else { return "Disabled" }
        if let reason = missingCredentialReason { return reason }
        if let health, health.status == "error" {
            return health.lastError ?? "Error"
        }
        if let health, health.status == "warning" {
            return health.lastError ?? "Warning"
        }
        if let health, health.status == "ok" {
            if isHealthStale { return "Last poll over \(staleMinutes) min ago" }
            switch service {
            case "imessage": return "Available"
            case "signal":   return signalAccount
            case "telegram": return "Credentials configured"
            case "slack":    return "\(slackWorkspaceCount) workspace\(slackWorkspaceCount == 1 ? "" : "s")"
            default:         return "Connected"
            }
        }
        return "Pending first poll"
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

    /// True only when the dot is green. Used to drive the icon's colour treatment
    /// so brand colours don't mislead at a glance.
    private var isStatusGreen: Bool {
        guard config.enabled, hasRequiredCredentials, let health else { return false }
        return health.status == "ok" && !isHealthStale
    }

    /// SF Symbol shown as a small badge on top of the (greyed) icon when status isn't green.
    private var statusBadgeIcon: String {
        if !config.enabled { return "pause.fill" }
        if !hasRequiredCredentials { return "exclamationmark" }
        if let health, health.status == "error" { return "xmark" }
        return "exclamationmark"
    }

    /// Pill label shown next to the toggle. Tells the user *what* action is needed
    /// rather than just "broken".
    private var toggleAdornmentLabel: String {
        if !hasRequiredCredentials { return "ACTION NEEDED" }
        if let health, health.status == "error" { return "ERROR" }
        if let health, health.status == "warning" || isHealthStale { return "PENDING" }
        return "PENDING"
    }

    /// True when the per-service credential criteria are satisfied. A green check still
    /// requires a successful poll on top of this — credentials present alone is not enough.
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

    /// Human-readable description of what's missing — only set when hasRequiredCredentials is false.
    /// Drives the status label so the user sees the exact next step instead of a vague warning.
    private var missingCredentialReason: String? {
        if hasRequiredCredentials { return nil }
        switch service {
        case "imessage":
            return "Full Disk Access required"
        case "signal":
            return signalAccount.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Phone number required"
                : "Signal daemon not reachable"
        case "telegram":
            if telegramApiId.trimmingCharacters(in: .whitespaces).isEmpty
                || telegramApiHash.trimmingCharacters(in: .whitespaces).isEmpty {
                return "API credentials required"
            }
            if !sessionFileExists { return "Sign-in required" }
            return "Not configured"
        case "slack":
            return "Add a workspace"
        default:
            return "Not configured"
        }
    }

    private var sessionFileExists: Bool {
        FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/.config/llmessenger/data/telegram/session.session"
        )
    }

    /// Reliably opens the Full Disk Access pane in System Settings. The direct deep-link
    /// often races with an already-running System Settings instance and flashes
    /// "is not open anymore" — terminating any existing instance first works around it.
    /// Fallback chain: deep-link → Privacy root → reveal the bundle in Finder so the
    /// user can drag it in manually.
    private func openFullDiskAccessSettings() {
        // 1. Politely quit any running System Settings so the deep-link reliably opens fresh.
        for app in NSWorkspace.shared.runningApplications
            where app.bundleIdentifier == "com.apple.systempreferences" {
            app.terminate()
        }
        // 2. After a tiny pause, open the deep link.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let urls = [
                // macOS 13+ canonical deep-link
                URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"),
                // Legacy form (still works on some installs)
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
                // Privacy root as last-ditch
                URL(string: "x-apple.systempreferences:com.apple.preference.security")
            ].compactMap { $0 }
            for url in urls {
                if NSWorkspace.shared.open(url) { return }
            }
            // 3. Final fallback: reveal LLMessenger.app in Finder so the user can drag
            //    it into the FDA list themselves.
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
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
