// LLMessenger/UI/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var database: AppDatabase? = nil
    var onRunSetup: (() -> Void)? = nil
    var onBuild7DaySummaries: (() async -> Void)? = nil
    var onSyncContacts: (() async -> Void)? = nil
    var onRetryService: ((String) async -> Void)? = nil

    var body: some View {
        TabView {
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "cpu") }
                .tag(0)

            ServiceSettingsTab(database: database,
                               onBuild7DaySummaries: onBuild7DaySummaries,
                               onSyncContacts: onSyncContacts,
                               onRetryService: onRetryService)
                .tabItem { Label("Services", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)

            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
                .tag(2)

            InstructionsSettingsTab()
                .tabItem { Label("Instructions", systemImage: "text.bubble") }
                .tag(3)

            AboutSettingsTab(onRunSetup: onRunSetup)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(4)
        }
        // 720pt comfortably fits five tabbed segments at the top — at 540pt macOS
        // collapses the tab bar into a "Navigation Tab Bar" chevron overlay and the
        // tab content gets cramped, especially on the AI tab with three provider blocks.
        .frame(width: 720, height: 560)
        .background(Theme.bg)
    }
}
