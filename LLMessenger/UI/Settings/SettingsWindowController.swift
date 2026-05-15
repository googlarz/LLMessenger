// LLMessenger/UI/Settings/SettingsWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let database: AppDatabase
    var onRunSetup: (() -> Void)?
    var onBuild7DaySummaries: (() async -> Void)?
    var onSyncContacts: (() async -> Void)?

    init(database: AppDatabase) {
        self.database = database

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LLMessenger Settings"
        window.titlebarAppearsTransparent = true
        window.appearance = .dark
        window.backgroundColor = NSColor(Theme.bg)
        window.setFrameAutosaveName("LLMessengerSettings")
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        // contentView set after super.init so we can capture self
        window.contentView = NSHostingView(rootView: SettingsView(
            database: database,
            onRunSetup: { [weak self] in self?.onRunSetup?() },
            onBuild7DaySummaries: { [weak self] in await self?.onBuild7DaySummaries?() },
            onSyncContacts: { [weak self] in await self?.onSyncContacts?() }
        ))
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
