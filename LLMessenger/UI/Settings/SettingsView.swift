// LLMessenger/UI/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var database: AppDatabase? = nil

    var body: some View {
        TabView {
            LLMSettingsTab()
                .tabItem { Label("AI Model", systemImage: "cpu") }
                .tag(0)

            ServiceSettingsTab(database: database)
                .tabItem { Label("Services", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)
        }
        .frame(width: 480, height: 340)
        .padding()
    }
}
