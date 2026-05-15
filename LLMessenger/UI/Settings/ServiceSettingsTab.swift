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
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconBackground)
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Toggle("", isOn: $config.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
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
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                    )
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

    private var statusColor: Color {
        guard config.enabled else { return Color(nsColor: .tertiaryLabelColor) }
        if let health, health.status == "error" { return .red }
        if let health, health.status == "warning" { return .orange }
        if let health, health.status == "ok" { return .green }
        // No health record yet — PollEngine hasn't confirmed status.
        // Don't trust isConnected for iMessage (isReadableFile ignores TCC/FDA).
        if service == "imessage" { return .orange }
        return isConnected ? .green : .orange
    }

    private var statusLabel: String {
        guard config.enabled else { return "Disabled" }
        if let health, health.status == "error" {
            return health.lastError ?? "Error"
        }
        if let health, health.status == "warning" {
            return health.lastError ?? "Warning"
        }
        if let health, health.status == "ok" {
            switch service {
            case "imessage": return "Available"
            case "signal":   return signalAccount
            case "telegram": return "Credentials configured"
            case "slack":    return "\(slackWorkspaceCount) workspace\(slackWorkspaceCount == 1 ? "" : "s")"
            default:         return "Connected"
            }
        }
        // No health record yet — show neutral status.
        switch service {
        case "imessage":
            return "Checking…"
        case "signal":
            return isConnected ? "Checking…" : "Phone number required"
        case "telegram":
            if isConnected && !sessionFileExists { return "Session required" }
            return isConnected ? "Checking…" : "API credentials required"
        default:
            return isConnected ? "Checking…" : "Not configured"
        }
    }

    private var sessionFileExists: Bool {
        FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/.config/llmessenger/data/telegram/session.session"
        )
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
