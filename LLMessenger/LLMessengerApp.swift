// LLMessenger/LLMessengerApp.swift
import SwiftUI

@main
struct LLMessengerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window is opened via SettingsWindowController from the menu bar
        Settings { EmptyView() }
    }
}
