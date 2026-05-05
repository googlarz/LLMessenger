// LLMessenger/UI/Settings/InstructionsSettingsTab.swift
import SwiftUI
import AppKit

struct InstructionsSettingsTab: View {
    @State private var prompt: String = ""
    @State private var theme: String = "system"
    @State private var pollInterval: Int = 60
    @State private var saveStatus: String = ""

    private let repo = SettingsRepository()

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))

                HStack {
                    Text("This prompt is prepended to every LLM request. Changes take effect on next launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") { prompt = PromptBuilder.defaultBasePrompt }
                        .buttonStyle(.borderless)
                }
            } header: {
                Text("System Prompt")
            }

            Section("Refresh Frequency") {
                Stepper("Poll every \(pollInterval) min",
                        value: $pollInterval, in: 5...240, step: 5)
            }

            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
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

    private func load() {
        let saved = repo.loadBasePrompt()
        prompt = saved.isEmpty ? PromptBuilder.defaultBasePrompt : saved
        theme = repo.loadTheme()
        pollInterval = repo.loadPollInterval()
    }

    private func save() {
        repo.saveBasePrompt(prompt)
        repo.saveTheme(theme)
        repo.savePollInterval(pollInterval)
        applyTheme(theme)
        saveStatus = "Saved ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
    }

    private func applyTheme(_ theme: String) {
        let appearance: NSAppearance? = switch theme {
        case "light": NSAppearance(named: .aqua)
        case "dark":  NSAppearance(named: .darkAqua)
        default:      nil
        }
        NSApp.appearance = appearance
    }
}
