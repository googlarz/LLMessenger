// LLMessenger/UI/Settings/ServiceSettingsTab.swift
import SwiftUI

// The canonical ordered list of services always shown in Settings.
private let kAllServices = ["imessage", "signal", "telegram"]

struct ServiceSettingsTab: View {
    // Pre-populated so the form always renders — load() overwrites with DB values.
    @State private var configs: [ServiceConfig] = kAllServices.map { ServiceConfig.default(for: $0) }
    @State private var signalAccount: String = ""
    @State private var telegramApiId: String = ""
    @State private var telegramApiHash: String = ""
    @State private var saveStatus: String = ""
    private let repo: SettingsRepository

    init(database: AppDatabase? = nil) {
        repo = SettingsRepository(database: database)
    }

    var body: some View {
        Form {
            ForEach($configs, id: \.service) { $cfg in
                Section(serviceName(cfg.service)) {
                    Toggle("Enabled", isOn: $cfg.enabled)

                    Picker("Privacy mode", selection: $cfg.privacyMode) {
                        Text("On demand").tag("on_demand")
                        Text("Eager (auto-summarise)").tag("eager")
                    }
                    .pickerStyle(.segmented)

                    Stepper("Poll every \(cfg.pollIntervalMinutes) min",
                            value: $cfg.pollIntervalMinutes,
                            in: 5...120, step: 5)
                }
            }

            Section("Signal account") {
                TextField("Phone number (+1234567890)", text: $signalAccount)
            }

            Section("Telegram credentials") {
                TextField("API ID", text: $telegramApiId)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Hash", text: $telegramApiHash)
                    .textFieldStyle(.roundedBorder)
                Text("Get these from my.telegram.org → API development tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onAppear { load() }
    }

    private func serviceName(_ id: String) -> String {
        switch id {
        case "imessage": return "iMessage"
        case "signal":   return "Signal"
        case "telegram": return "Telegram"
        default:         return id.capitalized
        }
    }

    private func load() {
        // Merge DB values on top of the pre-populated defaults.
        let dbConfigs = (try? repo.loadAllServiceConfigs()) ?? []
        let dbByService = Dictionary(uniqueKeysWithValues: dbConfigs.map { ($0.service, $0) })
        configs = kAllServices.map { service in
            dbByService[service] ?? ServiceConfig.default(for: service)
        }
        signalAccount = (try? repo.loadSignalAccount()) ?? ""
        let tgCreds = repo.loadTelegramCredentials()
        telegramApiId   = tgCreds.apiId
        telegramApiHash = tgCreds.apiHash
    }

    private func save() {
        do {
            for cfg in configs {
                try repo.saveServiceConfig(cfg)
            }
            try repo.saveSignalAccount(signalAccount)
            try repo.saveTelegramCredentials(apiId: telegramApiId, apiHash: telegramApiHash)
            NotificationCenter.default.post(name: .serviceConfigDidChange, object: nil)
            saveStatus = "Saved ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }
}
