// LLMessenger/UI/Settings/InstructionsSettingsTab.swift
import SwiftUI
import AppKit

struct InstructionsSettingsTab: View {
    /// Owned by SettingsView so unsaved edits survive switching tabs.
    @ObservedObject var model: InstructionsSettingsModel
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        WireLabel("System Prompt")

                        TextEditor(text: $model.values.prompt)
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

                        HStack(alignment: .top) {
                            Text(InstructionsCopy.promptTiming)
                                .font(Theme.sans(11))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Reset to Default") { showResetConfirmation = true }
                                .buttonStyle(WireActionStyle.textAction())
                                .confirmationDialog(
                                    "Reset system prompt to default?",
                                    isPresented: $showResetConfirmation,
                                    titleVisibility: .visible
                                ) {
                                    Button("Reset", role: .destructive) {
                                        model.resetPromptToDefault()
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("Your current prompt will be replaced in the editor. Choose Save to keep the change, or Discard to go back.")
                                }
                        }
                    }
                    .padding(.vertical, 14)

                    Rule()

                    VStack(alignment: .leading, spacing: 10) {
                        WireLabel("Digest Language")
                        TextField("English", text: $model.values.briefLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Text(InstructionsCopy.languageTiming)
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 14)

                    Rule()

                    VStack(alignment: .leading, spacing: 10) {
                        WireLabel("Appearance")
                        HStack {
                            Text("Theme")
                                .font(Theme.sans(12))
                                .foregroundStyle(Theme.textSecondary)
                            Picker("", selection: Binding(get: { model.theme },
                                                          set: { model.setTheme($0) })) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 250)
                        }
                        Text(InstructionsCopy.themeTiming)
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 14)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rule()

            SettingsSaveFooter(
                isDirty: model.isDirty,
                message: model.status == .saved ? "Saved" : nil,
                unsavedLabel: "Unsaved changes to the prompt or language",
                onSave: { model.save() },
                onDiscard: { model.discard() }
            )
        }
        .onAppear { model.load() }
    }
}
