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
            // Never shown to the user, but its AX container is still visited by
            // performAccessibilityAudit() and can vanish mid-query (this window
            // comes and goes), which crashes the audit with a snapshot-mismatch
            // error rather than a clean issue. Hide it from the AX tree entirely.
            EmptyView()
                .accessibilityHidden(true)
        }
        .defaultSize(width: 0, height: 0)
        .commandsRemoved()
    }
}
