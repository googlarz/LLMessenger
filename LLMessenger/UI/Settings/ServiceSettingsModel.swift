// LLMessenger/UI/Settings/ServiceSettingsModel.swift
//
// State behind the Services pane. Owned by SettingsView (not the pane) so edits
// survive switching panes.
//
// - On/off and poll interval save the moment they change: they have no "draft".
// - Credentials (Signal number, Telegram API ID/hash) stay behind an explicit Save,
//   and `hasUnsavedCredentials` drives the "Unsaved changes" bar. A background reload
//   never overwrites them while they are unsaved.

import Foundation

@MainActor
final class ServiceSettingsModel: ObservableObject {
    static let allServices = ["imessage", "signal", "telegram", "slack", "whatsapp"]

    struct Credentials: Equatable {
        var signalAccount = ""
        var telegramApiId = ""
        var telegramApiHash = ""
    }

    enum Status: Equatable {
        case idle
        case saved
        case error(String)
    }

    @Published private(set) var configs: [ServiceConfig]
    @Published var credentials = Credentials()
    @Published private(set) var savedCredentials = Credentials()
    @Published private(set) var healthByService: [String: ServiceHealth] = [:]
    @Published private(set) var status: Status = .idle

    private let repo: SettingsRepository
    private let center: NotificationCenter
    private var clearTask: Task<Void, Never>?

    init(repo: SettingsRepository, center: NotificationCenter = .default) {
        self.repo = repo
        self.center = center
        configs = Self.allServices.map { ServiceConfig.default(for: $0) }
    }

    var hasUnsavedCredentials: Bool { credentials != savedCredentials }

    // MARK: - Loading

    /// Re-reads configs and health. Credentials are only re-read when there are no
    /// unsaved edits, so a background health update can't wipe what the user typed.
    func reload() {
        let stored = (try? repo.loadAllServiceConfigs()) ?? []
        let byService = Dictionary(uniqueKeysWithValues: stored.map { ($0.service, $0) })
        configs = Self.allServices.map { byService[$0] ?? ServiceConfig.default(for: $0) }
        healthByService = (try? repo.loadAllServiceHealth()) ?? [:]
        if !hasUnsavedCredentials {
            let tg = repo.loadTelegramCredentials()
            let loaded = Credentials(signalAccount: (try? repo.loadSignalAccount()) ?? "",
                                     telegramApiId: tg.apiId,
                                     telegramApiHash: tg.apiHash)
            credentials = loaded
            savedCredentials = loaded
        }
    }

    func config(for service: String) -> ServiceConfig {
        configs.first { $0.service == service } ?? ServiceConfig.default(for: service)
    }

    // MARK: - Immediate saves

    /// Applies a change from a card. On/off and poll interval are saved at once and the app
    /// is told to re-arm polling; if the save fails the control goes back to what is stored.
    func update(_ config: ServiceConfig) {
        guard let index = configs.firstIndex(where: { $0.service == config.service }) else { return }
        let old = configs[index]
        guard old.enabled != config.enabled || old.pollIntervalSeconds != config.pollIntervalSeconds else { return }
        configs[index] = config
        do {
            try repo.saveServiceConfig(config)
            center.post(name: .serviceConfigDidChange, object: nil)
            flash(.saved)
        } catch {
            configs[index] = old
            status = .error("Couldn't save the \(Self.displayName(config.service)) setting: \(error.localizedDescription)")
        }
    }

    func setEnabled(_ enabled: Bool, for service: String) {
        var config = self.config(for: service)
        config.enabled = enabled
        update(config)
    }

    // MARK: - Credentials

    func saveCredentials() {
        do {
            try repo.saveSignalAccount(credentials.signalAccount)
            try repo.saveTelegramCredentials(apiId: credentials.telegramApiId, apiHash: credentials.telegramApiHash)
            savedCredentials = credentials
            center.post(name: .serviceConfigDidChange, object: nil)
            flash(.saved)
        } catch {
            // Keep what the user typed so they can fix it and try again.
            status = .error("Couldn't save: \(error.localizedDescription) Your changes are still here.")
        }
    }

    func discardCredentials() {
        credentials = savedCredentials
        status = .idle
    }

    // MARK: -

    private func flash(_ newStatus: Status) {
        status = newStatus
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.status == newStatus { self?.status = .idle }
        }
    }

    static func displayName(_ service: String) -> String {
        switch service {
        case "imessage": return "iMessage"
        case "signal":   return "Signal"
        case "telegram": return "Telegram"
        case "slack":    return "Slack"
        case "whatsapp": return "WhatsApp"
        default:         return service.capitalized
        }
    }
}
