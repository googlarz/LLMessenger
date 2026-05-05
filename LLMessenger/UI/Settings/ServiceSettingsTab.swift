// LLMessenger/UI/Settings/ServiceSettingsTab.swift
import SwiftUI

struct ServiceSettingsTab: View {
    @State private var configs: [ServiceConfig] = []
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
        if configs.isEmpty {
            configs = [ServiceConfig.default(for: "telegram")]
        }
    }

    private func save() {
        do {
            for cfg in configs {
                try repo.saveServiceConfig(cfg)
            }
            saveStatus = "Saved ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }
}
