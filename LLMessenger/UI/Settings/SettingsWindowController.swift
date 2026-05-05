// LLMessenger/UI/Settings/SettingsWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(database: AppDatabase) {
        let content = SettingsView(database: database)
        let hosting = NSHostingView(rootView: content)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLMessenger Settings"
        window.contentView = hosting
        window.center()
        window.setFrameAutosaveName("LLMessengerSettings")

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible == false {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep controller alive — don't nil it out, just let window hide
    }
}
