// LLMessenger/UI/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var database: AppDatabase? = nil

    var body: some View {
        TabView {
            InstructionsSettingsTab()
                .tabItem { Label("Instructions", systemImage: "text.bubble") }
                .tag(0)

            AISettingsTab()
                .tabItem { Label("AI", systemImage: "cpu") }
                .tag(1)

            ServiceSettingsTab(database: database)
                .tabItem { Label("Services", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(2)

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(3)
        }
        .frame(width: 520, height: 420)
        .padding()
    }
}
