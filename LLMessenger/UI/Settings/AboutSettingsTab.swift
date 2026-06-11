// LLMessenger/UI/Settings/AboutSettingsTab.swift
import SwiftUI

struct AboutSettingsTab: View {
    var onRunSetup: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                // Masthead: serif wordmark over a mono version line — typeset, not badged.
                VStack(spacing: 6) {
                    Text("LLMessenger")
                        .font(Theme.display(26))
                        .foregroundStyle(Theme.textPrimary)
                    Text("v\(appVersion)")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textTertiary)
                }

                Rule().frame(maxWidth: 320)

                VStack(spacing: 8) {
                    Text("Made by Dawid Piaskowski")
                        .font(Theme.sans(13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)

                    Link("github.com/googlarz/LLMessenger",
                         destination: URL(string: "https://github.com/googlarz/LLMessenger")!)
                        .font(Theme.mono(11))
                        .tint(Theme.textSecondary)
                }

                Rule().frame(maxWidth: 320)

                Text("Released under the MIT License\nFree to use, modify, and distribute")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                if let onRunSetup {
                    Button("Run Setup Wizard", action: onRunSetup)
                        .buttonStyle(PaperButtonStyle())
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}
