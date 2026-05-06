// LLMessenger/LLMessengerApp.swift
import SwiftUI

@main
struct LLMessengerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window is managed by SettingsWindowController (AppKit).
        // We need *some* scene for SwiftUI, but Settings { EmptyView() } would
        // intercept Cmd+, globally. WindowGroup with a non-openable ID avoids both issues.
        WindowGroup(id: "_noop") {
            EmptyView()
        }
        .defaultSize(width: 0, height: 0)
        .commandsRemoved()
    }
}
