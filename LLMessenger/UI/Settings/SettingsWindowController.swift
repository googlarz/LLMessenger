// LLMessenger/UI/Settings/SettingsWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLMessenger Settings"
        window.setFrameAutosaveName("LLMessengerSettings")
        window.contentView = NSHostingView(rootView: SettingsView(database: database))

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
