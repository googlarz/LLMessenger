// LLMessenger/LLMessengerApp.swift
import SwiftUI

@main
struct LLMessengerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(database: appDelegate.database)
        }
    }
}
