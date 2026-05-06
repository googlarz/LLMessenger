// LLMessenger/UI/Settings/ServiceSettingsTab.swift
import SwiftUI

struct ServiceSettingsTab: View {
    @State private var configs: [ServiceConfig] = []
    @State private var signalAccount: String = ""
    @State private var telegramApiId: String = ""
    @State private var telegramApiHash: String = ""
    @State private var saveStatus: String = ""
    private let repo: SettingsRepository

    init(database: AppDatabase? = nil) {
        repo = SettingsRepository(database: database)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if configs.isEmpty {
                Text("No services configured.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach($configs, id: \.service) { $cfg in
                        Section(cfg.service.capitalized) {
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

                    Section("Signal") {
                        TextField("Phone number (+1234567890)", text: $signalAccount)
                    }

                    Section("Telegram") {
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
            }
        }
        .onAppear { load() }
    }

    private func load() {
        configs = (try? repo.loadAllServiceConfigs()) ?? []
        for service in ["telegram", "signal", "imessage"] where !configs.contains(where: { $0.service == service }) {
            configs.append(ServiceConfig.default(for: service))
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
