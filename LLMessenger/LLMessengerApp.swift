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
            // Never shown to the user. `.accessibilityHidden` only hides SwiftUI
            // content — this window's own AXWindow object is created by AppKit,
            // so it's still visited by performAccessibilityAudit() and can crash
            // it if it vanishes mid-query. AppDelegate.hideNoopWindowFromAccessibility()
            // excludes the actual NSWindow from the AX tree; this modifier is
            // belt-and-suspenders for the content SwiftUI does control.
            EmptyView()
                .accessibilityHidden(true)
        }
        .defaultSize(width: 0, height: 0)
        .commandsRemoved()
    }
}
