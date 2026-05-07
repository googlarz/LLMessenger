// LLMessenger/UI/Settings/AboutSettingsTab.swift
import SwiftUI

struct AboutSettingsTab: View {
    var onRunSetup: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                // App icon
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Theme.accentMuted)
                        .frame(width: 72, height: 72)
                    Text("L")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                }

                VStack(spacing: 4) {
                    Text("LLMessenger")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Version \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                Divider().frame(maxWidth: 320).overlay(Theme.border)

                VStack(spacing: 8) {
                    Text("Made by Dawid Piaskowski")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)

                    Link("github.com/googlarz/LLMessenger",
                         destination: URL(string: "https://github.com/googlarz/LLMessenger")!)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                }

                Divider().frame(maxWidth: 320).overlay(Theme.border)

                Text("Released under the MIT License\nFree to use, modify, and distribute")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                if let onRunSetup {
                    Button(action: onRunSetup) {
                        Label("Run Setup Wizard", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(Theme.textSecondary)
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
