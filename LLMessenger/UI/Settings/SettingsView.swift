// LLMessenger/UI/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var database: AppDatabase? = nil
    var onRunSetup: (() -> Void)? = nil

    var body: some View {
        TabView {
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "cpu") }
                .tag(0)

            ServiceSettingsTab(database: database)
                .tabItem { Label("Services", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)

            InstructionsSettingsTab()
                .tabItem { Label("Instructions", systemImage: "text.bubble") }
                .tag(2)

            AboutSettingsTab(onRunSetup: onRunSetup)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(3)
        }
        .frame(width: 540, height: 480)
        .background(Theme.bg)
    }
}
