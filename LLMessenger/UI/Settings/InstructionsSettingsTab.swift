// LLMessenger/UI/Settings/InstructionsSettingsTab.swift
import SwiftUI
import AppKit

struct InstructionsSettingsTab: View {
    @State private var prompt: String = ""
    @State private var theme: String = "system"
    @State private var saveStatus: String = ""
    @State private var showResetConfirmation = false

    private let repo = SettingsRepository()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        WireLabel("System Prompt")

                        TextEditor(text: $prompt)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(minHeight: 140)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.controlRadius)
                                    .strokeBorder(Theme.border, lineWidth: Theme.hairline)
                            )

                        HStack {
                            Text("This prompt is prepended to every LLM request. Changes take effect on next launch.")
                                .font(Theme.sans(11))
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Button("Reset to Default") { showResetConfirmation = true }
                                .buttonStyle(WireActionStyle())
                                .confirmationDialog(
                                    "Reset system prompt to default?",
                                    isPresented: $showResetConfirmation,
                                    titleVisibility: .visible
                                ) {
                                    Button("Reset", role: .destructive) {
                                        prompt = PromptBuilder.defaultBasePrompt
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("Your current prompt will be replaced. This cannot be undone.")
                                }
                        }
                    }
                    .padding(.vertical, 14)

                    Rule()

                    VStack(alignment: .leading, spacing: 10) {
                        WireLabel("Appearance")
                        HStack {
                            Text("Theme")
                                .font(Theme.sans(12))
                                .foregroundStyle(Theme.textSecondary)
                            Picker("", selection: $theme) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 250)
                        }
                    }
                    .padding(.vertical, 14)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rule()

            HStack {
                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.ok)
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
    }

    private func load() {
        let saved = repo.loadBasePrompt()
        prompt = saved.isEmpty ? PromptBuilder.defaultBasePrompt : saved
        theme = repo.loadTheme()
    }

    private func save() {
        repo.saveBasePrompt(prompt)
        repo.saveTheme(theme)
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
