// LLMessenger/UI/Settings/SettingsWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let database: AppDatabase
    var onRunSetup: (() -> Void)?
    var onBuild7DaySummaries: (() async -> Void)?
    var onSyncContacts: (() async -> Void)?
    var onRetryService: ((String) async -> Void)?
    var onScheduleChanged: (() -> Void)?

    init(database: AppDatabase) {
        self.database = database

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 480)
        window.title = "LLMessenger Settings"
        window.titlebarAppearsTransparent = true
        window.appearance = .dark
        window.backgroundColor = NSColor(Theme.bg)
        // Bumped autosave key so the old cached 540×480 frame (saved before the Privacy
        // tab + wider layout) doesn't shrink the new larger window on first open.
        window.setFrameAutosaveName("LLMessengerSettings.v2")
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        // contentView set after super.init so we can capture self
        window.contentView = NSHostingView(rootView: SettingsView(
            database: database,
            onRunSetup: { [weak self] in self?.onRunSetup?() },
            onBuild7DaySummaries: { [weak self] in await self?.onBuild7DaySummaries?() },
            onSyncContacts: { [weak self] in await self?.onSyncContacts?() },
            onRetryService: { [weak self] svc in await self?.onRetryService?(svc) },
            onScheduleChanged: { [weak self] in self?.onScheduleChanged?() }
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
