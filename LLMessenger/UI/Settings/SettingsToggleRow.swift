// LLMessenger/UI/Settings/SettingsToggleRow.swift
import SwiftUI

/// A titled switch with a caption. The switch always sits on the trailing edge, so a stack
/// of these lines up whatever the caption length.
struct SettingsToggleRow: View {
    let title: String
    let caption: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.sans(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let caption {
                    Text(caption)
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.ok)
                .accessibilityLabel(title)
        }
    }
}
