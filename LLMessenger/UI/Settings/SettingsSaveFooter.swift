// LLMessenger/UI/Settings/SettingsSaveFooter.swift
import SwiftUI

/// The bar at the foot of a Settings pane that has an explicit Save. It says plainly when
/// there is something unsaved, and offers Discard next to Save.
struct SettingsSaveFooter: View {
    let isDirty: Bool
    /// "Saved" or an error message; shown when there is nothing unsaved.
    let message: String?
    let messageIsError: Bool
    let unsavedLabel: String
    let onSave: () -> Void
    let onDiscard: () -> Void

    init(isDirty: Bool, message: String? = nil, messageIsError: Bool = false,
         unsavedLabel: String = "Unsaved changes",
         onSave: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.isDirty = isDirty
        self.message = message
        self.messageIsError = messageIsError
        self.unsavedLabel = unsavedLabel
        self.onSave = onSave
        self.onDiscard = onDiscard
    }

    var body: some View {
        HStack(spacing: 12) {
            if isDirty {
                dot(Theme.standby, unsavedLabel)
                Button("Discard", action: onDiscard)
                    .buttonStyle(WireActionStyle())
            }
            if let message {
                dot(messageIsError ? Theme.signal : Theme.ok, message)
            }
            Spacer()
            Button("Save", action: onSave)
                .buttonStyle(PaperButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isDirty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func dot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
