// LLMessenger/UI/Settings/AboutSettingsTab.swift
import SwiftUI

struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                // App icon
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 72, height: 72)
                    Text("L")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 4) {
                    Text("LLMessenger")
                        .font(.system(size: 22, weight: .bold))
                    Text("Version \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider().frame(maxWidth: 320)

                VStack(spacing: 8) {
                    Text("Made by Dawid Piaskowski")
                        .font(.system(size: 13, weight: .medium))

                    Link("github.com/googlarz/LLMessenger",
                         destination: URL(string: "https://github.com/googlarz/LLMessenger")!)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }

                Divider().frame(maxWidth: 320)

                Text("Released under the MIT License\nFree to use, modify, and distribute")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}
